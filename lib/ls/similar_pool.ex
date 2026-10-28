defmodule LS.SimilarPool do
  @moduledoc """
  Keeps `ls.similar_pool` fresh: the candidates for the "businesses like
  this one" block on every company page, pre-selected per (business model,
  country, revenue tier), so the page reads one key range instead of
  scanning the product table.

  ## Why (2026-10-28)

  `LS.Clickhouse.similar_stores/6` filtered `businesses` by model, country
  and revenue tier. The table's sorting key is the domain, so every cache
  miss was a full scan: 3.0 to 5.8 s on average per model, 15.2 s at
  worst, on the 4-core box that serves customers. The 24 h cache could not
  help: its key space is models x countries x tiers x rank bands, and the
  visitors are crawlers walking /website/* and /shopify/* pages (1,700 of
  2,700 sessions in 30 days), each on a different company. From 00:00 to
  06:00 UTC on 2026-10-28 the block missed 176 times for 710 s of
  ClickHouse time, the second largest web cost on the master.

  ## How

  At most 80 ranked and 40 recent candidates per group, rebuilt once a day
  at 11:50 UTC (the quiet hour, right after the daily optimize) into a
  shadow table and swapped in with EXCHANGE TABLES, so readers never see an
  empty pool. The reader (`read_sql/5`) orders the group's candidates by
  nearest rank, preferring the ones ranked better than the target; an
  unranked target gets the most recently compiled peers. Master-only.
  Migration 031 creates and fills the table; while it is empty or missing
  `ready?/0` is false and the page falls back to the old scan.
  """
  use GenServer
  require Logger

  alias LS.Clickhouse
  alias LS.Schema.Tables

  # The daily rebuild starts here (UTC); the optimizer's pass is at 11:30.
  @hour 11
  @minute 50
  @first_check :timer.minutes(10)
  @build_timeout :timer.minutes(16)
  @shadow "similar_pool_build"
  # How long a "not ready" answer is believed before the table is asked again.
  @ready_recheck_ms :timer.minutes(10)
  @ranked_per_group 80
  @recent_per_group 40
  @unranked_rank 4_294_967_295

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Rebuild now, regardless of the schedule. Asynchronous."
  def rebuild_now, do: send(__MODULE__, :rebuild) && :ok

  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  True once the pool holds at least one row. A yes is cached for the life of
  the node; a no is believed for ten minutes, so a box without the table
  (migration not applied yet) does not ask ClickHouse on every page.
  """
  @spec ready?() :: boolean()
  def ready? do
    case :persistent_term.get({__MODULE__, :ready}, nil) do
      true ->
        true

      {false, checked_at} when is_integer(checked_at) ->
        if System.monotonic_time(:millisecond) - checked_at < @ready_recheck_ms, do: false, else: probe()

      _ ->
        probe()
    end
  end

  defp probe do
    case Clickhouse.query_raw("SELECT 1 FROM #{Tables.similar_pool()} LIMIT 1", 5_000) do
      {:ok, [_ | _]} ->
        :persistent_term.put({__MODULE__, :ready}, true)
        true

      _ ->
        :persistent_term.put({__MODULE__, :ready}, {false, System.monotonic_time(:millisecond)})
        false
    end
  end

  @doc """
  The INSERT that fills `table`. Kept identical to migration 031's first
  fill (LS.SimilarPoolTest pins both). FINAL: without it every version row
  of a company the compactor rewrote since the last optimize took a slot,
  and the harness showed each candidate twice (2026-10-28). Once a day at
  the quiet hour the merge is affordable.
  """
  @spec build_sql(String.t()) :: String.t()
  def build_sql(table \\ @shadow) do
    """
    INSERT INTO #{table}
    SELECT business_model, country, revenue, kind, rank, domain, http_title, tranco_rank, is_shopify, compiled_at, now()
    FROM (
      SELECT estimated_business_model AS business_model, estimated_country AS country, estimated_revenue AS revenue,
             'ranked' AS kind, toUInt32(tranco_rank) AS rank, domain, http_title, tranco_rank, is_shopify, compiled_at
      FROM #{Tables.businesses()} FINAL
      WHERE tranco_rank > 0 AND estimated_business_model != '' AND estimated_country != ''
        AND estimated_business_model_confidence >= 0.5 AND estimated_junk = '' AND http_title != ''
      ORDER BY business_model, country, revenue, rank
      LIMIT #{@ranked_per_group} BY business_model, country, revenue
      UNION ALL
      SELECT estimated_business_model AS business_model, estimated_country AS country, estimated_revenue AS revenue,
             'recent' AS kind, #{@unranked_rank} AS rank, domain, http_title, tranco_rank, is_shopify, compiled_at
      FROM #{Tables.businesses()} FINAL
      WHERE (tranco_rank IS NULL OR tranco_rank <= 0) AND estimated_business_model != '' AND estimated_country != ''
        AND estimated_business_model_confidence >= 0.5 AND estimated_junk = '' AND http_title != ''
        AND compiled_at >= now() - INTERVAL 90 DAY
      ORDER BY business_model, country, revenue, compiled_at DESC
      LIMIT #{@recent_per_group} BY business_model, country, revenue
    )
    SETTINGS max_threads = 2, max_insert_threads = 1, max_execution_time = 900, max_memory_usage = 2500000000, max_bytes_before_external_sort = 1000000000
    """
  end

  @doc """
  The page's read: the group's candidates, nearest to `rank` first and the
  ones ranked better than the target ahead of the ones ranked worse; for an
  unranked target (`nil`) the most recently compiled peers, then the ranked
  ones. `tiers` is the list of revenue labels the target compares to.
  Returns the same row shape as the old scan: domain, title, rank, shopify.
  """
  @spec read_sql(String.t(), String.t(), [String.t()], integer() | nil, pos_integer()) :: String.t()
  def read_sql(business_model, country, tiers, rank, limit) do
    tier_sql = Enum.map_join(tiers, ",", &"'#{Clickhouse.escape_public(&1)}'")

    order =
      case rank do
        r when is_integer(r) and r > 0 ->
          "kind = 'ranked' DESC, rank <= #{r} DESC, abs(toInt64(rank) - #{r}) ASC"

        _ ->
          "kind = 'recent' DESC, compiled_at DESC, rank ASC"
      end

    """
    SELECT domain, http_title, tranco_rank, is_shopify
    FROM #{Tables.similar_pool()}
    WHERE business_model = '#{Clickhouse.escape_public(business_model)}'
      AND country = '#{Clickhouse.escape_public(country)}'
      AND revenue IN (#{tier_sql})
    ORDER BY #{order}
    LIMIT #{limit}
    """
  end

  @doc "Seconds since the pool was built, or :empty."
  def age_s do
    case Clickhouse.query_raw("SELECT toInt32(dateDiff('second', max(built_at), now())) FROM #{Tables.similar_pool()} WHERE built_at > 0", 10_000) do
      {:ok, [[age]]} when is_integer(age) -> age
      _ -> :empty
    end
  end

  @doc "Build the shadow table and swap it in. Synchronous; `:ok` or `{:error, step, reason}`."
  def rebuild do
    t0 = System.monotonic_time(:millisecond)
    pool = Tables.similar_pool()

    with :ok <- ddl("DROP TABLE IF EXISTS #{@shadow}"),
         :ok <- ddl("CREATE TABLE #{@shadow} AS #{pool}"),
         :ok <- run(:build, build_sql(@shadow), @build_timeout),
         :ok <- ddl("EXCHANGE TABLES #{pool} AND #{@shadow}"),
         :ok <- ddl("DROP TABLE #{@shadow}") do
      :persistent_term.put({__MODULE__, :ready}, true)
      Logger.info("[SIMILAR-POOL] rebuilt in #{System.monotonic_time(:millisecond) - t0}ms")
      :ok
    end
  end

  defp ddl(sql), do: run(:ddl, sql, 60_000)

  defp run(step, sql, timeout) do
    case Clickhouse.query_raw(sql, timeout, background: true) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, step, reason}
    end
  end

  @doc "Milliseconds from `now` (UTC) to the next daily build at #{@hour}:#{@minute} UTC, never under a minute."
  @spec delay_to_build_ms(DateTime.t()) :: pos_integer()
  def delay_to_build_ms(%DateTime{} = now) do
    today = DateTime.new!(DateTime.to_date(now), Time.new!(@hour, @minute, 0), "Etc/UTC")
    diff = DateTime.diff(today, now, :millisecond)
    if diff >= 60_000, do: diff, else: diff + :timer.hours(24)
  end

  @impl true
  def init(_opts) do
    # A fresh box builds once soon after boot if the pool is empty (the
    # migration creates and fills it, so this is the exception), then daily.
    Process.send_after(self(), :first_check, @first_check)
    Process.send_after(self(), :rebuild, delay_to_build_ms(DateTime.utc_now()))
    {:ok, %{builds: 0, failures: 0, last_at: nil, last_ms: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:stats, _from, s), do: {:reply, s, s}

  @impl true
  def handle_info(:first_check, s) do
    if age_s() == :empty, do: {:noreply, do_rebuild(s)}, else: {:noreply, s}
  end

  def handle_info(:rebuild, s) do
    Process.send_after(self(), :rebuild, delay_to_build_ms(DateTime.utc_now()))
    {:noreply, do_rebuild(s)}
  end

  defp do_rebuild(s) do
    t0 = System.monotonic_time(:millisecond)

    case rebuild() do
      :ok ->
        %{s | builds: s.builds + 1, last_at: DateTime.utc_now(), last_ms: System.monotonic_time(:millisecond) - t0, last_error: nil}

      {:error, step, reason} ->
        # The table may not exist yet (migration 031 pending): the page keeps
        # its fallback scan; this is retried at the next scheduled build.
        Logger.warning("[SIMILAR-POOL] rebuild failed at #{step}: #{inspect(reason) |> String.slice(0, 300)}")
        %{s | failures: s.failures + 1, last_error: {step, reason}}
    end
  end
end
