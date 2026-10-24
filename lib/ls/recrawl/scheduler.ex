defmodule LS.Recrawl.Scheduler do
  @moduledoc """
  Tiered re-crawl scheduler: enqueues the businesses whose refresh cadence
  has elapsed (LS.Crawl.Tiers: A 14 days, B 90, C 180 since 2026-10-23), most valuable tier
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
  # Tier B and C refreshes are skipped while the work queue already holds
  # more than 150K domains, so they never bury discovery.
  #
  # Tier A is different (2026-10-24). Those are the online businesses with
  # revenue, jobs or a catalogue whose changes are the product, and the
  # headroom rule had paused them for 12 hours while certificate inflow
  # alone outran six workers. Every tick now enqueues up to
  # @tier_a_per_tick of them whatever the queue holds; the WorkQueue
  # dequeues them first (priority 0), so they are fetched within the tick.
  # 4,500 every 30 minutes is 216K a day, the 14-day plan for 3.13M tier A
  # businesses (223K), and about half of what six nodes fetch in a day,
  # leaving the other half to new names.
  @batch_size 12_500
  @tier_a_per_tick 4_500
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
      queue_headroom: @queue_headroom, max_passes: @max_passes,
      tier_a_per_tick: @tier_a_per_tick, tier_a_per_day: runs * @tier_a_per_tick}
  end

  @doc """
  Pure: may this due domain be enqueued this tick? Tier A: yes, until the
  tick's tier A allowance is spent, whatever the queue holds. Tier B or C:
  only while the queue is under the headroom.
  """
  @spec admit?(String.t(), non_neg_integer(), boolean()) :: boolean()
  def admit?("a", a_enqueued, _over_headroom), do: a_enqueued < @tier_a_per_tick
  def admit?(_tier, _a_enqueued, over_headroom), do: not over_headroom

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
      total_enqueued_a: 0,
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
    Logger.info("[RECRAWL] Checking for due businesses (tiers #{LS.Crawl.Tiers.cadence_days(:a)}/#{LS.Crawl.Tiers.cadence_days(:b)}/#{LS.Crawl.Tiers.cadence_days(:c)} days, queue depth #{depth})")
    over = depth > @queue_headroom

    if over,
      do: Logger.info("[RECRAWL] Queue holds #{depth}, over the #{@queue_headroom} headroom: tier A only this tick")

    # Two lanes, each reading only its own tiers (2026-10-24). Tier A first,
    # up to its allowance whatever the queue holds; B and C with what is
    # left of the tick, only under the headroom (admit?/3 is the rule).
    {a_enqueued, a_dead, a_full} = lane(["a"], @tier_a_per_tick, a_block())

    {bc_enqueued, bc_dead} =
      if a_full or not admit?("b", 0, over),
        do: {0, 0},
        else: lane(["b", "c"], quota_left(a_enqueued), @batch_size) |> then(fn {n, d, _} -> {n, d} end)

    enqueued = a_enqueued + bc_enqueued
    dead = a_dead + bc_dead
    Logger.info("[RECRAWL] Tick done: enqueued #{enqueued} live (tier A #{a_enqueued}, B/C #{bc_enqueued}), #{dead} dead recorded on the master")
    # Survives a restart of this process: LS.Metrics.recrawl/0 reads it so
    # a crash loop (2026-10-23) cannot hide behind a fresh uptime.
    :persistent_term.put({__MODULE__, :last_tick}, System.system_time(:second))

    %{state |
      total_enqueued: state.total_enqueued + enqueued,
      total_enqueued_a: Map.get(state, :total_enqueued_a, 0) + a_enqueued,
      total_dead: Map.get(state, :total_dead, 0) + dead,
      total_checks: state.total_checks + 1,
      last_check_at: DateTime.utc_now(),
      last_batch_size: enqueued}
  end

  @doc "Pure: how many live names this tick may still enqueue."
  @spec quota_left(non_neg_integer()) :: non_neg_integer()
  def quota_left(enqueued), do: max(@batch_size - enqueued, 0)

  @doc """
  Pure: how many tier A rows one pass reads. A quarter more than the
  allowance covers the dead share of a known business (a few percent)
  without resolving 12,500 names on the master to use 4,500.
  """
  @spec a_block() :: pos_integer()
  def a_block, do: min(@batch_size, @tier_a_per_tick + div(@tier_a_per_tick, 4))

  # One lane: blocks of `block` rows from the due list restricted to
  # `tiers`, at successive offsets, until `target` live names are enqueued,
  # the list ends, or @max_passes blocks were read. Returns
  # `{enqueued, dead_recorded, queue_full?}`.
  defp lane(_tiers, target, _block) when target <= 0, do: {0, 0, false}

  defp lane(tiers, target, block) do
    try do
      passes(tiers, target, block, 0, 0, 0)
    catch
      {:queue_full, enqueued, dead} -> {enqueued, dead, true}
    end
  end

  defp passes(_tiers, target, _block, pass, enqueued, dead) when pass >= @max_passes or enqueued >= target,
    do: {enqueued, dead, false}

  defp passes(tiers, target, block, pass, enqueued, dead) do
    case LS.Clickhouse.stale_domains(block, pass * block, tiers) do
      {:ok, []} ->
        Logger.info("[RECRAWL] No stale #{Enum.join(tiers, "/")} domains found at offset #{pass * block}")
        {enqueued, dead, false}

      {:ok, domains} ->
        count = length(domains)
        Logger.info("[RECRAWL] Found #{count} stale #{Enum.join(tiers, "/")} domains at offset #{pass * block}, pass #{pass + 1}/#{@max_passes}")

        # Resolve on the master first (LS.Recrawl.Liveness, 2026-10-03): a
        # dead name gets its check recorded here and never costs a worker
        # batch. A suspect resolver sends the whole block on, as before.
        # Only as many as this lane can still enqueue are resolved, and
        # nothing the queue already holds (WorkQueue.queued?/1): a tier B
        # item waits hours behind discovery and its compiled row still says
        # due at the next tick.
        domains = Enum.reject(domains, fn {d, _tier, _simhash} -> LS.Cluster.WorkQueue.queued?(d) end)

        {domains, dead_recorded} =
          case LS.Recrawl.Liveness.partition(Enum.take(domains, target - enqueued)) do
            {:ok, live, dead_list} ->
              case LS.Recrawl.Liveness.record_dead(dead_list) do
                {:ok, n} -> {live, n}
                {:error, reason} ->
                  Logger.error("[RECRAWL] could not record #{length(dead_list)} dead domains: #{inspect(reason)}")
                  {live, 0}
              end

            {:error, :resolver_suspect} ->
              Logger.error("[RECRAWL] master resolver failed an anchor name; sending all #{count} to workers")
              {Enum.take(domains, target - enqueued), 0}
          end

        added =
          Enum.reduce(domains, 0, fn {domain, tier, simhash}, acc ->
            # Use the same :ctl_domain key CTL items carry so the worker pipeline
            # (enrich_dns/merge_results) can read it uniformly regardless of source.
            # The stored homepage simhash lets the worker skip the secondary
            # pages of an unchanged site (2026-10-23). The tier rides along
            # so the queue can put tier A first (WorkQueue.priority/1).
            data = %{ctl_domain: domain, source: :recrawl, tier: tier, prev_simhash: simhash}
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

        Logger.info("[RECRAWL] Enqueued #{added}/#{count} stale #{Enum.join(tiers, "/")} domains (#{dead_recorded} dead recorded on the master)")

        if count < block,
          do: {enqueued + added, dead + dead_recorded, false},
          else: passes(tiers, target, block, pass + 1, enqueued + added, dead + dead_recorded)

      {:error, reason} ->
        Logger.error("[RECRAWL] ClickHouse query failed: #{inspect(reason)}")
        {enqueued, dead, false}
    end
  end
end
