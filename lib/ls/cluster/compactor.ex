defmodule LS.Cluster.Compactor do
  @moduledoc """
  Keeps the `businesses` product table fresh. Master-only.

  `businesses` is the flat, export-ready row per company that the app, the
  API and CSV downloads all read. It is *compiled*, never written directly by
  a pipeline — discovery writes `domains_history`, enrichment writes `biz_*`,
  and this process folds both into one row per domain.

  ## Incremental, not nightly

  A full rebuild costs ~8 minutes because it coalesces the whole 126M-row
  history. Doing that once a night would leave the product up to 24h stale and
  waste CPU recomputing 6.36M rows when only a few thousand changed. Instead
  we run every `@interval_ms` over **only the domains touched since the last
  pass** (~15K at current throughput), which takes well under a second:
  `businesses` is a `ReplacingMergeTree(as_of)`, so re-inserting a domain's row
  *is* the update.

  The expensive full rebuild remains available as `rebuild_all/0` — a repair
  tool for after an incident, not a routine job.

  ## Why coalescing still matters here

  Rows are assembled with "last **non-empty** value per signal unit"
  (`argMaxIf`), not "newest row wins". A crawl that failed, or a stage that was
  skipped, therefore cannot blank a field that an earlier crawl filled — the
  bug that spoiled ~7.8M domains before this existed.
  """

  use GenServer
  require Logger

  alias LS.Clickhouse

  @interval_ms 300_000
  # Overlap the window so a row inserted while the previous pass was running is
  # not missed; re-doing a few domains is free, losing one is not.
  @lookback_slack_s 120

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Compaction counters and the timestamp of the last successful pass."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Run one incremental pass immediately."
  def compact_now, do: send(__MODULE__, :compact) && :ok

  @doc """
  Full rebuild of `businesses` from scratch (~8 min, memory-bounded).

  Use after data corruption; the routine path is the incremental pass.
  """
  def rebuild_all, do: GenServer.call(__MODULE__, :rebuild_all, 30 * 60_000)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :compact, 60_000)
    Logger.info("🧩 Compactor started (every #{div(@interval_ms, 1000)}s, incremental)")
    {:ok, %{passes: 0, domains: 0, last_at: nil, last_ms: nil, since: initial_since()}}
  end

  @impl true
  def handle_call(:stats, _from, s), do: {:reply, s, s}

  @impl true
  def handle_call(:rebuild_all, _from, s) do
    t0 = System.monotonic_time(:millisecond)
    result = Clickhouse.rebuild_businesses_full()
    Logger.info("[COMPACT] full rebuild: #{inspect(result)} in #{System.monotonic_time(:millisecond) - t0}ms")
    {:reply, result, s}
  end

  @impl true
  def handle_info(:compact, s) do
    t0 = System.monotonic_time(:millisecond)
    until = now_s()

    s =
      case Clickhouse.compact_businesses(s.since - @lookback_slack_s) do
        {:ok, count} ->
          if count > 0 do
            Logger.info("[COMPACT] refreshed #{count} businesses in #{System.monotonic_time(:millisecond) - t0}ms")
          end

          %{s |
            passes: s.passes + 1,
            domains: s.domains + count,
            last_at: DateTime.utc_now(),
            last_ms: System.monotonic_time(:millisecond) - t0,
            since: until}

        {:error, reason} ->
          # Keep `since` unchanged so the next pass retries the same window.
          Logger.error("[COMPACT] failed: #{inspect(reason)}")
          %{s | passes: s.passes + 1}
      end

    Process.send_after(self(), :compact, @interval_ms)
    {:noreply, s}
  end

  defp now_s, do: System.system_time(:second)
  defp initial_since, do: now_s() - div(@interval_ms, 1000)
end
