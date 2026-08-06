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

  # Max enrichment-window one pass may cover (~10K domains at current rates,
  # ~2 min of query). This bound is the fix for the 2026-08-05 death spiral:
  # an open-ended catch-up window meant one timeout guaranteed every retry a
  # larger batch, and compaction never recovered — 19h of stale depth data.
  @catchup_slice_s 1_800

  @doc "Where this pass's window must stop. Pure, so the spiral-proof bound is testable."
  def slice_until(since_s, now_s), do: min(now_s, since_s + @catchup_slice_s)

  @doc """
  Kick a sharded full rebuild in the background (the backfill tool).
  Runs OUTSIDE the GenServer so incremental compaction keeps its cadence;
  progress lands in the log every shard.
  """
  def rebuild_sharded(total_shards \\ 256) do
    Task.start(fn ->
      t0 = System.monotonic_time(:millisecond)

      failures =
        Enum.reduce(0..(total_shards - 1), 0, fn shard, failed ->
          case Clickhouse.compact_shard(shard, total_shards) do
            {:ok, _} ->
              if rem(shard + 1, 16) == 0 do
                elapsed = div(System.monotonic_time(:millisecond) - t0, 60_000)
                Logger.info("[COMPACT] backfill #{shard + 1}/#{total_shards} shards (#{elapsed}m, #{failed} failed)")
              end

              failed

            {:error, reason} ->
              Logger.error("[COMPACT] backfill shard #{shard} failed: #{inspect(reason)}")
              failed + 1
          end
        end)

      Logger.info("[COMPACT] backfill DONE: #{total_shards} shards, #{failures} failed, #{div(System.monotonic_time(:millisecond) - t0, 60_000)}m")
    end)
  end

  @impl true
  def handle_info(:compact, s) do
    t0 = System.monotonic_time(:millisecond)
    now = now_s()
    until = slice_until(s.since, now)
    behind? = until < now - 120

    s =
      case Clickhouse.compact_businesses(s.since - @lookback_slack_s, until) do
        {:ok, count} ->
          if count > 0 do
            lag = if behind?, do: " (catching up, #{div(now - until, 60)}m behind)", else: ""
            Logger.info("[COMPACT] refreshed #{count} businesses in #{System.monotonic_time(:millisecond) - t0}ms#{lag}")
          end

          %{s |
            passes: s.passes + 1,
            domains: s.domains + count,
            last_at: DateTime.utc_now(),
            last_ms: System.monotonic_time(:millisecond) - t0,
            since: until}

        {:error, reason} ->
          # Keep `since` unchanged so the next pass retries the SAME bounded
          # slice — never a bigger one.
          Logger.error("[COMPACT] failed: #{inspect(reason)}")
          %{s | passes: s.passes + 1}
      end

    # When behind, run the next slice almost immediately instead of waiting a
    # full interval — catch-up at ~2 min per 30-min slice, not 7 min each.
    Process.send_after(self(), :compact, if(behind?, do: 2_000, else: @interval_ms))
    {:noreply, s}
  end

  defp now_s, do: System.system_time(:second)
  defp initial_since, do: now_s() - div(@interval_ms, 1000)
end
