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

  # 150K per run, four runs a day: a 600K-a-day refresh ceiling, which is
  # what tiers A+B+C add up to at steady state (430K + 140K + 50K). The run
  # is skipped while the work queue already holds more than half a million
  # domains, so a refresh never buries discovery.
  @batch_size 150_000
  @queue_headroom 500_000
  @check_interval_ms 6 * 3_600_000  # 6 hours
  # Wait 5 minutes after boot before first check (let CTL/workers warm up)
  @initial_delay_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
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
      "batch: #{@batch_size}, interval: #{div(@check_interval_ms, 3_600_000)}h"
    )
    Process.send_after(self(), :check_stale, @initial_delay_ms)

    {:ok, %{
      total_enqueued: 0,
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

    case if(depth > @queue_headroom, do: {:ok, []}, else: LS.Clickhouse.stale_domains(@batch_size)) do
      {:ok, []} ->
        Logger.info("[RECRAWL] No stale domains found")
        %{state | total_checks: state.total_checks + 1, last_check_at: DateTime.utc_now(), last_batch_size: 0}

      {:ok, domains} ->
        count = length(domains)
        Logger.info("[RECRAWL] Found #{count} stale domains, enqueuing for re-crawl")

        enqueued = Enum.reduce(domains, 0, fn {domain, tier}, acc ->
          # Use the same :ctl_domain key CTL items carry so the worker pipeline
          # (enrich_dns/merge_results) can read it uniformly regardless of source.
          data = %{ctl_domain: domain, source: :recrawl, tier: tier}
          # This IS the 7-day schedule: stale_domains already selected only
          # domains 7+ (or 30+) days old, so the dedup gate has nothing to add
          # and could hold a day-7 domain until its window rotates (day 8).
          case LS.Cluster.WorkQueue.enqueue(data, force: true) do
            :ok -> acc + 1
            :queue_full ->
              Logger.warning("[RECRAWL] WorkQueue full, stopping enqueue at #{acc}/#{count}")
              throw({:queue_full, acc})
            _ -> acc
          end
        end)

        Logger.info("[RECRAWL] Enqueued #{enqueued}/#{count} stale domains")
        %{state |
          total_enqueued: state.total_enqueued + enqueued,
          total_checks: state.total_checks + 1,
          last_check_at: DateTime.utc_now(),
          last_batch_size: enqueued}

      {:error, reason} ->
        Logger.error("[RECRAWL] ClickHouse query failed: #{inspect(reason)}")
        %{state | total_checks: state.total_checks + 1, last_check_at: DateTime.utc_now(), last_batch_size: 0}
    end
  catch
    {:queue_full, enqueued} ->
      %{state |
        total_enqueued: state.total_enqueued + enqueued,
        total_checks: state.total_checks + 1,
        last_check_at: DateTime.utc_now(),
        last_batch_size: enqueued}
  end
end
