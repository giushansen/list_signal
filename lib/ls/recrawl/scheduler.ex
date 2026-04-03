defmodule LS.Recrawl.Scheduler do
  @moduledoc """
  Tiered re-crawl scheduler.

  Periodically queries ClickHouse for stale domains and enqueues them
  for re-enrichment via the WorkQueue.

  Tiers:
    - Weekly (7 days): Ecommerce, SaaS, Tool, Marketplace, Agency
    - Monthly (30 days): everything else

  Runs every 6 hours, fetching a batch of the most stale domains
  (prioritized by Tranco rank) and feeding them into the pipeline.
  """

  use GenServer
  require Logger

  @weekly_days 7
  @monthly_days 30
  @batch_size 5_000
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
      "weekly: #{@weekly_days}d (digital biz), monthly: #{@monthly_days}d (rest), " <>
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
    Logger.info("[RECRAWL] Checking for stale domains (weekly: #{@weekly_days}d, monthly: #{@monthly_days}d)")

    case LS.Clickhouse.stale_domains(@weekly_days, @monthly_days, @batch_size) do
      {:ok, []} ->
        Logger.info("[RECRAWL] No stale domains found")
        %{state | total_checks: state.total_checks + 1, last_check_at: DateTime.utc_now(), last_batch_size: 0}

      {:ok, domains} ->
        count = length(domains)
        Logger.info("[RECRAWL] Found #{count} stale domains, enqueuing for re-crawl")

        enqueued = Enum.reduce(domains, 0, fn domain, acc ->
          data = %{domain: domain, source: :recrawl}
          case LS.Cluster.WorkQueue.enqueue(data) do
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
