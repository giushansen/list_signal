defmodule LS.Recrawl.Scheduler do
  @moduledoc """
  Tiered re-crawl scheduler: enqueues the businesses whose refresh cadence
  has elapsed (LS.Crawl.Tiers: A 14 days, B 60, C 120), most valuable tier
  first, every six hours, with `force: true` so the daily and tier rings
  do not second-guess the schedule. The stable and dormant rings still
  apply: an unchanged site drifts to 28-35 or 60-90 days by itself.

  Before 2026-10-03 this was 7 days for five digital models and 30 for
  everything else, 5,000 domains per run read from the 57 GB `domains`
  table with FINAL; at 20K a day it was never the refresh path, certificate
  re-sightings were. Now it is the refresh path and the re-sightings are
  gated by tier.
  """

  use GenServer
  require Logger

  # 12,500 per run, every 30 minutes: a 600K-a-day refresh ceiling, which
  # is what tiers A+B+C add up to at steady state (430K + 140K + 50K). Small
  # and often, not 150K every six hours (the first form, 2026-10-03
  # morning): a block of known businesses makes refresh-only batches, and a
  # known business passes the gate 93% of the time against 37% for a new
  # name, so those batches carried 930 HTTP candidates instead of 370, ran
  # 25 minutes against a shared ceiling and some died at their deadline.
  # Mixed into discovery at this rate a batch stays near 450 candidates.
  # The run is skipped while the work queue already holds more than
  # 150K domains, so a refresh never buries discovery.
  @batch_size 12_500
  @queue_headroom 150_000
  @check_interval_ms 30 * 60_000
  # Wait 5 minutes after boot before first check (let CTL/workers warm up)
  @initial_delay_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Passes per tick. The liveness check (LS.Recrawl.Liveness) found 73% of
  # each 12,500 block dead on 2026-10-03, so one pass enqueued 3,150 live
  # names, a quarter of the budget. A tick now reads further down the due
  # list (same order, next offset) until it has enqueued batch_size live
  # names or has read this many blocks. Dead names cost a lookup each, no
  # fetch, so the fetch budget is unchanged.
  @max_passes 4

  @doc "The refresh plan: domains per run, runs per day, and the daily ceiling they make."
  def plan do
    runs = div(24 * 3_600_000, @check_interval_ms)
    %{batch_size: @batch_size, interval_ms: @check_interval_ms, runs_per_day: runs, per_day: runs * @batch_size,
      queue_headroom: @queue_headroom, max_passes: @max_passes}
  end

  @doc "Manually trigger a recrawl check."
  def check_now do
    send(__MODULE__, :check_stale)
    :ok
  end

  @impl true
  def init(_opts) do
    Logger.info(
      "[RECRAWL] Scheduler started — " <>
      "tiers A/B/C: #{LS.Crawl.Tiers.cadence_days(:a)}/#{LS.Crawl.Tiers.cadence_days(:b)}/#{LS.Crawl.Tiers.cadence_days(:c)} days, " <>
      "batch: #{@batch_size}, interval: #{div(@check_interval_ms, 60_000)}min"
    )
    Process.send_after(self(), :check_stale, @initial_delay_ms)

    {:ok, %{
      total_enqueued: 0,
      total_dead: 0,
      total_checks: 0,
      last_check_at: nil,
      last_batch_size: 0,
      start_time: System.monotonic_time(:second)
    }}
  end

  @impl true
  def handle_info(:check_stale, state) do
    state = do_check(state)
    Process.send_after(self(), :check_stale, @check_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.put(state, :uptime_seconds, System.monotonic_time(:second) - state.start_time), state}
  end

  defp do_check(state) do
    depth = LS.Cluster.WorkQueue.stats()[:queue_depth] || 0
    Logger.info("[RECRAWL] Checking for due businesses (tiers 14/60/120 days, queue depth #{depth})")

    if depth > @queue_headroom do
      Logger.info("[RECRAWL] Queue holds #{depth}, over the #{@queue_headroom} headroom: no refresh this tick")
      %{state | total_checks: state.total_checks + 1, last_check_at: DateTime.utc_now(), last_batch_size: 0}
    else
      {enqueued, dead} = passes(0, 0, 0)
      Logger.info("[RECRAWL] Tick done: enqueued #{enqueued} live, #{dead} dead recorded on the master")

      %{state |
        total_enqueued: state.total_enqueued + enqueued,
        total_dead: Map.get(state, :total_dead, 0) + dead,
        total_checks: state.total_checks + 1,
        last_check_at: DateTime.utc_now(),
        last_batch_size: enqueued}
    end
  catch
    {:queue_full, enqueued, dead} ->
      %{state |
        total_enqueued: state.total_enqueued + enqueued,
        total_dead: Map.get(state, :total_dead, 0) + dead,
        total_checks: state.total_checks + 1,
        last_check_at: DateTime.utc_now(),
        last_batch_size: enqueued}
  end

  @doc "Pure: how many live names this tick may still enqueue."
  @spec quota_left(non_neg_integer()) :: non_neg_integer()
  def quota_left(enqueued), do: max(@batch_size - enqueued, 0)

  # One block of the due list per pass, at the next offset; stops at the
  # live target, at the end of the due list, or after @max_passes blocks.
  defp passes(pass, enqueued, dead) when pass >= @max_passes or enqueued >= @batch_size, do: {enqueued, dead}

  defp passes(pass, enqueued, dead) do
    case LS.Clickhouse.stale_domains(@batch_size, pass * @batch_size) do
      {:ok, []} ->
        Logger.info("[RECRAWL] No stale domains found at offset #{pass * @batch_size}")
        {enqueued, dead}

      {:ok, domains} ->
        count = length(domains)
        Logger.info("[RECRAWL] Found #{count} stale domains at offset #{pass * @batch_size}, pass #{pass + 1}/#{@max_passes}")

        # Resolve on the master first (LS.Recrawl.Liveness, 2026-10-03): a
        # dead name gets its check recorded here and never costs a worker
        # batch. A suspect resolver sends the whole block on, as before.
        {domains, dead_recorded} =
          case LS.Recrawl.Liveness.partition(domains) do
            {:ok, live, dead_list} ->
              case LS.Recrawl.Liveness.record_dead(dead_list) do
                {:ok, n} -> {live, n}
                {:error, reason} ->
                  Logger.error("[RECRAWL] could not record #{length(dead_list)} dead domains: #{inspect(reason)}")
                  {live, 0}
              end

            {:error, :resolver_suspect} ->
              Logger.error("[RECRAWL] master resolver failed an anchor name; sending all #{count} to workers")
              {domains, 0}
          end

        # Only the quota left in this tick: the third block of the first
        # multi-block ticks pushed 22,491 and 18,921 live names into a
        # 12,500 plan (2026-10-03). The rest stay due and lead the next tick.
        added = domains |> Enum.take(quota_left(enqueued)) |> Enum.reduce(0, fn {domain, tier}, acc ->
          # Use the same :ctl_domain key CTL items carry so the worker pipeline
          # (enrich_dns/merge_results) can read it uniformly regardless of source.
          data = %{ctl_domain: domain, source: :recrawl, tier: tier}
          # This IS the schedule: stale_domains already selected only domains
          # past their cadence, so the daily and tier rings have nothing to add.
          case LS.Cluster.WorkQueue.enqueue(data, force: true) do
            :ok -> acc + 1
            :queue_full ->
              Logger.warning("[RECRAWL] WorkQueue full, stopping enqueue at #{enqueued + acc}")
              throw({:queue_full, enqueued + acc, dead + dead_recorded})
            _ -> acc
          end
        end)

        Logger.info("[RECRAWL] Enqueued #{added}/#{count} stale domains (#{dead_recorded} dead recorded on the master)")

        if count < @batch_size,
          do: {enqueued + added, dead + dead_recorded},
          else: passes(pass + 1, enqueued + added, dead + dead_recorded)

      {:error, reason} ->
        Logger.error("[RECRAWL] ClickHouse query failed: #{inspect(reason)}")
        {enqueued, dead}
    end
  end
end
