defmodule LS.TechIndex do
  @moduledoc """
  Keeps `ls.tech_index` fresh: one row per (technology, titled domain),
  sorted by (tech, rank, domain), so every public technology page reads one
  key range instead of scanning `domains_current`.

  ## Why (2026-09-09)

  `/tech/*`, `/top/*`, `/compare/*`, the directory and the sitemap all ran
  `http_tech LIKE '%X%'` over a 193M-row table whose sorting key is the
  domain. Nothing can index that. Measured over 24 hours: 1,844 such
  queries at 29.5s average and 119s at p95, 54,483 CPU-seconds and 7.6 TiB
  read, 72% of all ClickHouse read time together with the other
  `domains_fast` readers, on the box that also serves customers. It is the
  shape of the 09-07 storm too (415 concurrent scans, "Search unavailable").

  ## How

  A full rebuild every six hours into a shadow table, then
  `EXCHANGE TABLES`, so readers never see an empty index. The read side is
  33s for 147M rows at ~100 MB (measured on prod), on the background pool
  with a server-side ceiling. Six hours matches the TTL the page caches
  already had; the data describes populations that move by the day.
  Master-only. Migration 024 creates and fills the table so the first
  request after a deploy has data; this server only keeps it current.

  A rebuild that fails leaves the previous index in place and is retried at
  the next check; the tech pages keep serving the old data. `ready?/0` lets
  the tech page refuse to cache an assembly made against an empty index
  (a fresh box before its first build).
  """
  use GenServer
  require Logger

  alias LS.Clickhouse

  @interval :timer.hours(6)
  @first_check :timer.minutes(5)
  # A rebuild is due when the newest row is older than this. Slightly above
  # the interval so a slow pass does not double-build.
  @max_age_s 7 * 3600
  @build_timeout :timer.minutes(35)
  @shadow "tech_index_build"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Rebuild now, regardless of age. Asynchronous."
  def rebuild_now, do: send(__MODULE__, :rebuild) && :ok

  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "True once the index holds at least one row. Cached after the first yes."
  @spec ready?() :: boolean()
  def ready? do
    :persistent_term.get({__MODULE__, :ready}, false) or
      case Clickhouse.query_raw("SELECT 1 FROM tech_index LIMIT 1", 5_000) do
        {:ok, [_ | _]} -> :persistent_term.put({__MODULE__, :ready}, true) == :ok
        _ -> false
      end
  end

  @doc """
  The INSERT that fills `table`. Kept identical to migration 024's first
  fill (LS.TechIndexTest pins both). FINAL so a domain re-enriched between
  merges counts once; the exact-token ARRAY JOIN is the meaning change the
  migration documents.
  """
  @spec build_sql(String.t()) :: String.t()
  def build_sql(table \\ @shadow) do
    """
    INSERT INTO #{table}
    SELECT
        tech, ifNull(toUInt32(tranco_rank), 4294967295) AS rank, domain, http_title, http_tech, country,
        tranco_rank, majestic_rank, is_shopify, http_status, http_response_time, http_language,
        rdap_registrar, rdap_domain_created_at, bgp_asn_org, dns_mx, http_emails, enriched_at, now()
    FROM domains_current FINAL
    ARRAY JOIN splitByChar('|', http_tech) AS tech
    WHERE http_tech != '' AND http_title != '' AND tech != ''
    SETTINGS max_threads = 2, max_insert_threads = 1, max_execution_time = 1700, max_memory_usage = 3000000000
    """
  end

  @doc "Seconds since the newest row was built; `:empty` when there is no index yet."
  def age_s do
    # toInt32: JSON output quotes 64-bit integers, and dateDiff is Int64.
    case Clickhouse.query_raw("SELECT toInt32(dateDiff('second', max(built_at), now())) FROM tech_index WHERE built_at > 0", 10_000) do
      {:ok, [[age]]} when is_integer(age) -> age
      _ -> :empty
    end
  end

  @doc false
  def stale?(:empty), do: true
  def stale?(age) when is_integer(age), do: age > @max_age_s

  @doc "Build the shadow table and swap it in. Synchronous; returns `:ok` or `{:error, step, reason}`."
  def rebuild do
    t0 = System.monotonic_time(:millisecond)

    with :ok <- ddl("DROP TABLE IF EXISTS #{@shadow}"),
         :ok <- ddl("CREATE TABLE #{@shadow} AS tech_index"),
         :ok <- run(:build, build_sql(@shadow), @build_timeout),
         :ok <- ddl("EXCHANGE TABLES tech_index AND #{@shadow}"),
         :ok <- ddl("DROP TABLE #{@shadow}") do
      :persistent_term.put({__MODULE__, :ready}, true)
      Logger.info("[TECH-INDEX] rebuilt in #{System.monotonic_time(:millisecond) - t0}ms")
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

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check, @first_check)
    {:ok, %{builds: 0, failures: 0, last_at: nil, last_ms: nil, last_error: nil}}
  end

  @impl true
  def handle_call(:stats, _from, s), do: {:reply, s, s}

  @impl true
  def handle_info(:check, s) do
    Process.send_after(self(), :check, @interval)
    if stale?(age_s()), do: {:noreply, do_rebuild(s)}, else: {:noreply, s}
  end

  def handle_info(:rebuild, s), do: {:noreply, do_rebuild(s)}

  defp do_rebuild(s) do
    t0 = System.monotonic_time(:millisecond)

    case rebuild() do
      :ok ->
        %{s | builds: s.builds + 1, last_at: DateTime.utc_now(), last_ms: System.monotonic_time(:millisecond) - t0, last_error: nil}

      {:error, step, reason} ->
        Logger.error("[TECH-INDEX] rebuild failed at #{step}: #{inspect(reason) |> String.slice(0, 300)}")
        %{s | failures: s.failures + 1, last_error: {step, reason}}
    end
  end
end
