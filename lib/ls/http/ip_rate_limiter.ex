defmodule LS.HTTP.IPRateLimiter do
  @moduledoc """
  ACTUAL IP-based rate limiting that WORKS.

  Tracks last request time per IP in ETS.
  Enforces minimum delay between requests to same IP.
  Logs stats for analysis and tuning.

  NEW: Tracks wait events to detect bottlenecks!
  """

  @ets_table :http_ip_rate_limiter

  # Shared edges (2026-10-01). Shopify's 1.4M storefronts resolve to a
  # handful of addresses in 23.227.38.0/24, so a per-address key let every
  # node send one request a second to each address in parallel while Shopify
  # counted them all as one client: 3.6% of Shopify fetches ended in 429
  # against 0.37% fleet-wide, and 82,309 stores held a 429 as their last
  # result. One key per shared edge makes the node wait between any two
  # requests to that vendor. Wix and Squarespace front their sites the same
  # way. Cloudflare is NOT here: it limits per zone, not per client, and
  # collapsing 5.9M sites onto one key would starve the fleet.
  @shared_edges [
    {"shopify", ["23.227.38."]},
    {"squarespace", ["198.185.159.", "198.49.23."]},
    {"wix", ["185.230.60.", "185.230.61.", "185.230.62.", "185.230.63.", "23.236.62."]}
  ]

  @doc "The key an address is limited under: the vendor name for a shared edge, else the address."
  @spec limiter_key(String.t()) :: String.t()
  def limiter_key(ip) when is_binary(ip) do
    Enum.find_value(@shared_edges, ip, fn {vendor, prefixes} ->
      if Enum.any?(prefixes, &String.starts_with?(ip, &1)), do: "edge:" <> vendor
    end)
  end
  @ets_wait_stats :http_ip_wait_stats
  @ets_penalty :http_ip_penalty
  @default_delay_ms 3000 # Safe with 1000ms if used in residential address

  # The spacing a shared edge gets whatever the caller asked for (2026-11-03).
  # Measured on the 24 h to 11-03 08:00 UTC: 92.4% of the fleet's 429s came
  # from the Shopify edge, 5.05% of Shopify fetches (4,188 of 82,906), with
  # one request a second per node to the edge; 15.9% on sg2, 7.2% on chi2.
  # Shopify publishes no number and tightened its unsigned-bot limits on
  # 2026-05-30; crawler vendors run it at 500 ms between request starts
  # and back off on 429. Two seconds per node is the setpoint until the
  # 429 rate on the edge reads under 1%.
  @edge_spacing_ms %{"edge:shopify" => 2_000}

  # Back-off after a 429 or a 503 (2026-11-03). The first one pauses the
  # key for @penalty_base_ms, each further one within @penalty_memory_ms
  # doubles it, up to @penalty_max_ms; a Retry-After longer than that
  # schedule wins. Until now nothing read Retry-After and the next request
  # to the same edge left one spacing later.
  @penalty_base_ms 5_000
  @penalty_max_ms 300_000
  @penalty_memory_ms 600_000

  def init do
    try do
      :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
      :ets.new(@ets_penalty, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
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
    ip = limiter_key(ip)
    delay_ms = max(delay_ms, Map.get(@edge_spacing_ms, ip, 0))
    now = System.monotonic_time(:millisecond)

    case penalty_wait(ip, now) do
      0 -> check_spacing(ip, delay_ms, now)
      wait_ms -> record_wait(wait_ms); {:wait, wait_ms}
    end
  end

  # A booking further out than this is refused instead of slept (2026-11-03).
  @max_book_ms 10_000

  @doc """
  Book the next request to a key: `:ok` to go now, `{:wait, ms}` with the
  key reserved for the caller that many ms from now, `{:refuse, ms}` when
  the key is paused or its line is already booked more than #{@max_book_ms}
  ms ahead (nothing is reserved then).

  Why (2026-11-03, two hours into the ny1 trial): `check_and_update/2`
  only answers "too soon", so the ten Shopify candidates a batch starts at
  once all slept the same two seconds and raced again; the losers burned
  the node budget slot they already held and came back as our own
  refusals, 15% of the first half hour's rows and 5.7% of the first two
  hours'. A booking spaces concurrent callers one after the other at the
  key's spacing, so the edge sees exactly the setpoint and no slot is
  burned. Same spacing as before: a booked caller never fires closer to
  the previous booking than `delay_ms`.
  """
  @spec book(String.t(), pos_integer()) :: :ok | {:wait, pos_integer()} | {:refuse, pos_integer()}
  def book(ip, delay_ms \\ @default_delay_ms) when is_binary(ip) do
    key = limiter_key(ip)
    delay_ms = max(delay_ms, Map.get(@edge_spacing_ms, key, 0))
    now = System.monotonic_time(:millisecond)

    case penalty_wait(key, now) do
      0 -> book_spacing(key, delay_ms, now)
      wait_ms -> record_wait(wait_ms); {:refuse, wait_ms}
    end
  end

  # The key's last booking is moved forward by `delay_ms` atomically, so two
  # concurrent callers get two different times. A line in the past is
  # claimed by one caller at `now`, as `LS.HTTP.NodeBudget.take/2` does.
  defp book_spacing(key, delay_ms, now) do
    claimed =
      :ets.select_replace(@ets_table, [
        {{key, :"$1"}, [{:<, :"$1", now - delay_ms}], [{{{:const, key}, now}}]}
      ])

    cond do
      claimed == 1 ->
        :ok

      :ets.insert_new(@ets_table, {key, now}) ->
        :ok

      true ->
        fire_at = :ets.update_counter(@ets_table, key, {2, delay_ms})
        wait_ms = fire_at - now

        cond do
          wait_ms <= 0 ->
            :ok

          wait_ms > @max_book_ms ->
            :ets.update_counter(@ets_table, key, {2, -delay_ms})
            record_wait(wait_ms)
            {:refuse, wait_ms}

          true ->
            record_wait(wait_ms)
            {:wait, wait_ms}
        end
    end
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Pause a key after the target said slow down: `retry_after_ms` from the
  response when it carried one, else the doubling schedule. Returns the
  pause in ms. Keyed like `check_and_update/2`, so one Shopify store's 429
  pauses the node's whole Shopify edge.
  """
  @spec penalize(String.t(), non_neg_integer() | nil) :: non_neg_integer()
  def penalize(ip, retry_after_ms \\ nil) when is_binary(ip) do
    key = limiter_key(ip)
    now = System.monotonic_time(:millisecond)

    level =
      case :ets.lookup(@ets_penalty, key) do
        [{^key, _until, level, at}] when now - at < @penalty_memory_ms -> level + 1
        _ -> 1
      end

    schedule = min(@penalty_base_ms * Integer.pow(2, level - 1), @penalty_max_ms)
    pause = max(schedule, min(retry_after_ms || 0, @penalty_max_ms))
    :ets.insert(@ets_penalty, {key, now + pause, level, now})
    :ets.update_counter(@ets_wait_stats, :penalties, {2, 1}, {:penalties, 0})
    pause
  rescue
    ArgumentError -> 0
  end

  @doc "Milliseconds a key is still paused for, 0 when it is not."
  @spec penalty_wait(String.t(), integer()) :: non_neg_integer()
  def penalty_wait(key, now \\ System.monotonic_time(:millisecond)) do
    case :ets.lookup(@ets_penalty, limiter_key(key)) do
      [{_, until, _level, _at}] when until > now -> until - now
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "The spacing a key is held to, whatever a caller passes."
  @spec min_spacing_ms(String.t()) :: non_neg_integer()
  def min_spacing_ms(ip) when is_binary(ip), do: Map.get(@edge_spacing_ms, limiter_key(ip), 0)

  defp check_spacing(ip, delay_ms, now) do
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
    penalties = case :ets.lookup(@ets_wait_stats, :penalties) do [{_, n}] -> n; _ -> 0 end

    %{
      unique_ips: size,
      penalties: penalties,
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
