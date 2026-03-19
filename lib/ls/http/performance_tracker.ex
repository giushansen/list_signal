defmodule LS.HTTP.PerformanceTracker do
  @moduledoc """
  Simple performance tracking - logs to file every 10 seconds.

  Tracks:
  - Request timing (fast vs slow)
  - Pool exhaustion events
  - Error breakdown
  - Throughput over time
  """

  use GenServer
  require Logger
  alias LS.HTTP.IPRateLimiter

  @log_file "http_performance.log"
  @print_interval 900_000

  defmodule State do
    defstruct [
      # Counters
      total: 0,
      successful: 0,

      # Timing buckets
      fast_requests: 0,      # < 200ms (likely cached session)
      medium_requests: 0,    # 200-1000ms
      slow_requests: 0,      # > 1000ms (full handshake)

      # Errors
      pool_timeouts: 0,
      dns_errors: 0,
      connection_errors: 0,
      tls_errors: 0,
      other_errors: 0,

      # System
      start_time: nil,
      last_print: nil,
      samples: []  # Last 100 timing samples
    ]
  end

  # ============================================================================
  # CLIENT API
  # ============================================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def record_success(elapsed_ms) do
    GenServer.cast(__MODULE__, {:success, elapsed_ms})
  end

  def record_error(reason) when is_binary(reason) do
    GenServer.cast(__MODULE__, {:error, reason})
  end
  def record_error(_), do: :ok

  def stats do
    GenServer.call(__MODULE__, :stats, 30_000)
  end

  # ============================================================================
  # GENSERVER CALLBACKS
  # ============================================================================

  @impl true
  def init(_) do
    File.write!(@log_file, "timestamp,total,successful,fast,medium,slow,pool_timeout,dns,conn,tls,other,rate,unique_ips,total_waits,avg_wait_ms,max_wait_ms\n")

    # Initialize rate limiter
    IPRateLimiter.init()

    state = %State{
      start_time: System.monotonic_time(:second),
      last_print: System.monotonic_time(:second)
    }

    schedule_print()
    {:ok, state}
  end

  @impl true
  def handle_cast({:success, elapsed_ms}, state) do
    {fast, medium, slow} = categorize_timing(elapsed_ms, state)

    new_state = %{state |
      total: state.total + 1,
      successful: state.successful + 1,
      fast_requests: fast,
      medium_requests: medium,
      slow_requests: slow,
      samples: add_sample(state.samples, elapsed_ms)
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:error, reason}, state) when is_binary(reason) do
    new_state = %{state | total: state.total + 1}

    new_state = cond do
      String.contains?(reason, "pool_timeout") ->
        %{new_state | pool_timeouts: state.pool_timeouts + 1}

      String.contains?(reason, ["nxdomain", "dns"]) ->
        %{new_state | dns_errors: state.dns_errors + 1}

      String.contains?(reason, ["econnrefused", "closed", "timeout"]) ->
        %{new_state | connection_errors: state.connection_errors + 1}

      String.contains?(reason, ["tls", "ssl", "handshake", "certificate"]) ->
        %{new_state | tls_errors: state.tls_errors + 1}

      true ->
        %{new_state | other_errors: state.other_errors + 1}
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, build_stats(state), state}
  end

  @impl true
  def handle_info(:print_metrics, state) do
    now = System.monotonic_time(:second)

    if now - state.last_print >= 10 do
      log_to_file(state)
      new_state = %{state | last_print: now}
      schedule_print()
      {:noreply, new_state}
    else
      schedule_print()
      {:noreply, state}
    end
  end

  # ============================================================================
  # HELPERS
  # ============================================================================

  defp categorize_timing(elapsed_ms, state) do
    cond do
      elapsed_ms < 200 ->
        {state.fast_requests + 1, state.medium_requests, state.slow_requests}
      elapsed_ms < 1000 ->
        {state.fast_requests, state.medium_requests + 1, state.slow_requests}
      true ->
        {state.fast_requests, state.medium_requests, state.slow_requests + 1}
    end
  end

  defp build_stats(state) do
    elapsed = System.monotonic_time(:second) - state.start_time
    rate = if elapsed > 0, do: Float.round(state.successful / elapsed, 2), else: 0.0

    failed = state.pool_timeouts + state.dns_errors + state.connection_errors +
             state.tls_errors + state.other_errors

    # Calculate session reuse estimate
    total_timed = state.fast_requests + state.medium_requests + state.slow_requests
    cache_hit_estimate = if total_timed > 0 do
      Float.round(state.fast_requests / total_timed * 100, 1)
    else
      0.0
    end

    {p50, p95, p99} = calculate_percentiles(state.samples)

    %{
      total: state.total,
      successful: state.successful,
      failed: failed,
      rate: rate,
      elapsed_sec: elapsed,

      # Timing breakdown
      fast_pct: cache_hit_estimate,
      medium_requests: state.medium_requests,
      slow_requests: state.slow_requests,

      # Latency
      p50_ms: p50,
      p95_ms: p95,
      p99_ms: p99,

      # Errors
      pool_timeouts: state.pool_timeouts,
      dns_errors: state.dns_errors,
      connection_errors: state.connection_errors,
      tls_errors: state.tls_errors,
      other_errors: state.other_errors
    }
  end

  defp log_to_file(state) do
    stats = build_stats(state)
    rate_limit_stats = IPRateLimiter.stats()
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    line = "#{timestamp},#{stats.total},#{stats.successful},#{state.fast_requests}," <>
           "#{state.medium_requests},#{state.slow_requests},#{stats.pool_timeouts}," <>
           "#{stats.dns_errors},#{stats.connection_errors},#{stats.tls_errors}," <>
           "#{stats.other_errors},#{stats.rate},#{rate_limit_stats.unique_ips}," <>
           "#{rate_limit_stats.total_waits},#{rate_limit_stats.avg_wait_ms}," <>
           "#{rate_limit_stats.max_wait_ms}\n"

    File.write!(@log_file, line, [:append])

    # Also print to console with wait stats
    wait_pct = if stats.total > 0, do: Float.round(rate_limit_stats.total_waits / stats.total * 100, 1), else: 0.0
    Logger.info("📊 #{stats.rate}/sec | Fast: #{stats.fast_pct}% | IPs: #{rate_limit_stats.unique_ips} | Waits: #{wait_pct}% (avg #{rate_limit_stats.avg_wait_ms}ms, max #{rate_limit_stats.max_wait_ms}ms)")
  end

  defp calculate_percentiles([]), do: {0, 0, 0}
  defp calculate_percentiles(samples) do
    sorted = Enum.sort(samples)
    len = length(sorted)

    p50 = Enum.at(sorted, div(len, 2)) || 0
    p95 = Enum.at(sorted, div(len * 95, 100)) || 0
    p99 = Enum.at(sorted, div(len * 99, 100)) || 0

    {p50, p95, p99}
  end

  defp add_sample(samples, value) do
    [value | Enum.take(samples, 999)]
  end

  defp schedule_print do
    Process.send_after(self(), :print_metrics, @print_interval)
  end
end
