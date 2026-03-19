defmodule LS.HTTP.IPRateLimiter do
  @moduledoc """
  ACTUAL IP-based rate limiting that WORKS.

  Tracks last request time per IP in ETS.
  Enforces minimum delay between requests to same IP.
  Logs stats for analysis and tuning.

  NEW: Tracks wait events to detect bottlenecks!
  """

  @ets_table :http_ip_rate_limiter
  @ets_wait_stats :http_ip_wait_stats
  @default_delay_ms 3000 # Safe with 1000ms if used in residential address

  def init do
    try do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      :ets.new(@ets_wait_stats, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      :ets.insert(@ets_wait_stats, {:total_waits, 0})
      :ets.insert(@ets_wait_stats, {:total_wait_time_ms, 0})
      :ets.insert(@ets_wait_stats, {:max_wait_ms, 0})
    rescue
      ArgumentError -> :ok  # Tables already exist
    end
  end

  @doc """
  Check if we can make a request to this IP right now.
  If too soon, returns {:wait, ms_to_wait}.
  If OK, updates last-seen time and returns :ok.

  Tracks wait statistics for bottleneck analysis.
  """
  def check_and_update(ip, delay_ms \\ @default_delay_ms) when is_binary(ip) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@ets_table, ip) do
      [{^ip, last_time}] ->
        elapsed = now - last_time

        if elapsed >= delay_ms do
          # Enough time has passed - allow request
          :ets.insert(@ets_table, {ip, now})
          :ok
        else
          # Too soon - need to wait
          wait_ms = delay_ms - elapsed

          # Track wait event
          record_wait(wait_ms)

          {:wait, wait_ms}
        end

      [] ->
        # First request to this IP - allow it
        :ets.insert(@ets_table, {ip, now})
        :ok
    end
  end

  defp record_wait(wait_ms) do
    # Increment total waits
    :ets.update_counter(@ets_wait_stats, :total_waits, {2, 1})

    # Add to total wait time
    :ets.update_counter(@ets_wait_stats, :total_wait_time_ms, {2, wait_ms})

    # Update max wait if this is higher
    case :ets.lookup(@ets_wait_stats, :max_wait_ms) do
      [{:max_wait_ms, current_max}] when wait_ms > current_max ->
        :ets.insert(@ets_wait_stats, {:max_wait_ms, wait_ms})
      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Get stats about rate limiting.
  Returns number of unique IPs tracked, memory usage, and wait statistics.
  """
  def stats do
    size = :ets.info(@ets_table, :size) || 0
    memory_words = :ets.info(@ets_table, :memory) || 0
    memory_mb = Float.round(memory_words * :erlang.system_info(:wordsize) / 1024 / 1024, 2)

    # Get wait stats
    [{:total_waits, total_waits}] = :ets.lookup(@ets_wait_stats, :total_waits)
    [{:total_wait_time_ms, total_wait_ms}] = :ets.lookup(@ets_wait_stats, :total_wait_time_ms)
    [{:max_wait_ms, max_wait_ms}] = :ets.lookup(@ets_wait_stats, :max_wait_ms)

    avg_wait_ms = if total_waits > 0, do: Float.round(total_wait_ms / total_waits, 1), else: 0.0

    %{
      unique_ips: size,
      memory_mb: memory_mb,
      total_waits: total_waits,
      avg_wait_ms: avg_wait_ms,
      max_wait_ms: max_wait_ms,
      total_wait_time_sec: Float.round(total_wait_ms / 1000, 1)
    }
  end

  @doc """
  Clear old entries (IPs not seen in last hour).
  Call periodically to prevent memory bloat.
  """
  def cleanup(max_age_ms \\ 3_600_000) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - max_age_ms

    :ets.select_delete(@ets_table, [
      {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
    ])
  end

  @doc """
  Reset wait statistics (useful for testing different settings).
  """
  def reset_wait_stats do
    :ets.insert(@ets_wait_stats, {:total_waits, 0})
    :ets.insert(@ets_wait_stats, {:total_wait_time_ms, 0})
    :ets.insert(@ets_wait_stats, {:max_wait_ms, 0})
  end
end
