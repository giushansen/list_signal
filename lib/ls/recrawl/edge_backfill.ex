defmodule LS.Recrawl.EdgeBackfill do
  @moduledoc """
  Keeps the Shopify line busy with the stores we found by DNS and never
  read, whenever first visits and refreshes leave it room (2026-11-12).
  Master-only.

  Measured on 2026-11-11/12: 2.72M domains resolved to Shopify's edge in
  `enrich_log` and were never fetched (DNS-only rows of July to
  September). Of the 29,377 such stores a certificate renewal brought back
  in 24 h, 94.7% answered 200, 81.8% were live English or French stores
  and 20.2% had an email: the best yield of any fetch the fleet makes. A
  renewal brings each one back about every two months, so they arrive at
  the rate the line can serve them only while the line is full. When it is
  not (a node added, renewals fading), this feeder reads the next page of
  the backlog and queues it.

  Ordering, the owner's rule: first visits a certificate brought now
  (priority -1) before tier A refreshes (0) before this backlog (1). The
  feeder only reads while the edge's first visits are on time and the
  queue holds few stores of the two kinds ahead of it, so a backlog item
  is not queued to expire: an expired item would have marked the daily
  ring and kept a fresh sighting of the same store out for a week.

  Each item is `%{ctl_domain: d, source: :backfill, edge: true}` through
  the ordinary `WorkQueue.enqueue/2`, so the daily, stable, dormant and
  tier rings and the queue's one-domain-one-place rule all apply. The
  walk is a keyset cursor over sorted domain ranges (`LS.Backfill.Ranges`),
  saved in `LS.State.dir/0` so a deploy resumes it; at the end it wraps,
  and stores fetched since drop out of the query by themselves.
  """

  use GenServer
  require Logger

  alias LS.Backfill.Ranges
  alias LS.Schema.Tables

  @tick_ms 10 * 60_000
  @first_ms 15 * 60_000
  @page 2_000
  # Read more only while fewer than this many backlog stores wait.
  @floor 3_000
  # ...and while fewer than this many stores wait ahead of them
  # (first visits at -1 and refreshes at 0).
  @ahead_max 2_000
  # A store whose last sighting is older than this has likely gone.
  @alive_days 120
  @cursor_file "edge_backfill_cursor.bin"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Counters and the cursor."
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Pure: may the feeder read another page? Only while the edge's first
  visits are on time (`WorkQueue.first_visit_health/0`), fewer than
  #{@ahead_max} stores wait ahead of the backlog, and fewer than #{@floor}
  backlog stores already wait.
  """
  @spec feed?(map(), map()) :: boolean()
  def feed?(health, stats) when is_map(health) and is_map(stats) do
    ahead = num(stats[:queue_depth_edge_sightings]) + num(stats[:queue_depth_priority])
    Map.get(health, :edge, :ok) == :ok and ahead < @ahead_max and num(stats[:queue_depth_backfill]) < @floor
  end

  def feed?(_, _), do: false

  @doc "Pure: the SQL for one page of never-fetched Shopify stores at `cursor`."
  @spec page_sql({non_neg_integer(), String.t() | nil}) :: String.t()
  def page_sql({index, after_domain}) do
    """
    SELECT domain FROM #{Tables.enrich_log()}
    WHERE #{Ranges.where_sql(Ranges.at(index), after_domain)}
    GROUP BY domain
    HAVING max(startsWith(bgp_ip, '23.227.38.')) = 1
       AND max(coalesce(http_status, 0) > 0) = 0
       AND max(enriched_at) >= now() - INTERVAL #{@alive_days} DAY
    ORDER BY domain
    LIMIT #{@page}
    SETTINGS max_threads = 2, max_execution_time = 120
    """
  end

  @doc "Pure: the queue item for one backlog store."
  @spec item(String.t()) :: map()
  def item(domain), do: %{ctl_domain: domain, source: :backfill, edge: true}

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_ms)
    cursor = Ranges.load(cursor_path())
    Logger.info("[BACKFILL] Shopify backlog feeder started at range #{elem(cursor, 0)} of #{Ranges.count()}")
    {:ok, %{cursor: cursor, pages: 0, read: 0, enqueued: 0, laps: 0, last_at: nil}}
  end

  @impl true
  def handle_call(:stats, _from, s), do: {:reply, s, s}

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, maybe_feed(s)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp maybe_feed(s) do
    health = LS.Cluster.WorkQueue.first_visit_health()
    stats = LS.Cluster.WorkQueue.stats()

    if feed?(health, stats), do: feed(s), else: s
  catch
    kind, reason ->
      Logger.warning("[BACKFILL] skipped a tick: #{inspect({kind, reason}) |> String.slice(0, 200)}")
      s
  end

  # One tick reads pages until it has a page of stores or has run
  # @queries_per_tick queries: most ranges hold a few hundred, some none.
  @queries_per_tick 20

  defp feed(s), do: feed(s, 0, 0)

  defp feed(s, queries, read) when queries >= @queries_per_tick or read >= @page, do: s

  defp feed(s, queries, read) do
    case LS.Clickhouse.query_raw(page_sql(s.cursor), 150_000) do
      {:ok, rows} when is_list(rows) ->
        domains = Ranges.safe_domains(rows)
        added = Enum.count(domains, &(LS.Cluster.WorkQueue.enqueue(item(&1)) == :ok))

        {cursor, laps} =
          case Ranges.advance(s.cursor, domains, @page) do
            :done -> {{0, nil}, s.laps + 1}
            next -> {next, s.laps}
          end

        Ranges.save(cursor_path(), cursor)

        if domains != [],
          do: Logger.info("[BACKFILL] range #{elem(s.cursor, 0)}: read #{length(domains)} never-fetched Shopify stores, queued #{added}")

        s = %{s | cursor: cursor, laps: laps, pages: s.pages + 1, read: s.read + length(domains), enqueued: s.enqueued + added, last_at: DateTime.utc_now()}
        feed(s, queries + 1, read + length(domains))

      other ->
        Logger.warning("[BACKFILL] page query failed: #{inspect(other) |> String.slice(0, 300)}")
        s
    end
  end

  defp cursor_path, do: Path.join(LS.State.dir(), @cursor_file)

  defp num(n) when is_integer(n) and n >= 0, do: n
  defp num(_), do: 0
end
