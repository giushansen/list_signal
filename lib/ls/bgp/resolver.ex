defmodule LS.BGP.Resolver do
  @moduledoc """
  BGP/ASN lookup using Team Cymru IP-to-ASN service.

  Uses Team Cymru's bulk whois interface (whois.cymru.com:43) with:
  - Batching: 50 IPs per query (smaller = more reliable)
  - Rate limiting: 2 second delays between batches (very polite)
  - ETS caching: 14-day TTL (extended from 24h for better coverage)
  - Generous timeouts: 2 minutes socket, 2.5 minutes GenServer

  Team Cymru is free and asks only that we be respectful.
  """

  use GenServer
  require Logger

  @cymru_host ~c"whois.cymru.com"
  @cymru_port 43
  @batch_size 100  # Smaller batches = faster, more reliable responses
  @batch_delay 2000  # 2 seconds between batches (very polite)
  @socket_timeout 120_000  # 2 minutes (Team Cymru can be slow)
  @genserver_timeout 150_000  # 2.5 minutes for GenServer.call
  @cache_ttl 1_209_600  # 14 days (2 weeks)
  @cleanup_interval 21_600_000  # Clean up every 6 hours

  # ============================================================================
  # CLIENT API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lookup BGP info for an IP address.

  Returns cached result if available, otherwise queries Team Cymru.

  ## Examples

      iex> lookup("8.8.8.8")
      {:ok, %{
        asn: "15169",
        org: "GOOGLE, US",
        country: "US",
        prefix: "8.8.8.0/24"
      }}
  """
  def lookup(ip) when is_binary(ip) do
    GenServer.call(__MODULE__, {:lookup, ip}, @genserver_timeout)
  end

  @doc """
  Lookup multiple IPs in a single batch query.

  More efficient than calling lookup/1 repeatedly.
  Respects Team Cymru's batching recommendations.
  """
  def lookup_batch(ips) when is_list(ips) do
    GenServer.call(__MODULE__, {:lookup_batch, ips}, @genserver_timeout)
  end

  @doc "Get resolver stats"
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ============================================================================
  # GENSERVER CALLBACKS
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS cache for IP -> ASN mappings with timestamps
    # Format: {ip, {result, timestamp}}
    # This table is created by LS.Cache.init_all(), but ensure it exists
    unless :ets.whereis(:bgp_ip_cache) != :undefined do
      :ets.new(:bgp_ip_cache, [:set, :public, :named_table, read_concurrency: true])
    end

    state = %{
      total_queries: 0,
      cache_hits: 0,
      cache_misses: 0,
      batch_count: 0,
      timeouts: 0,
      start_time: System.monotonic_time(:second)
    }

    Logger.info("🌐 BGP Resolver: Using Team Cymru (whois.cymru.com:43)")
    Logger.info("   Batch size: #{@batch_size} IPs (optimized)")
    Logger.info("   Batch delay: #{@batch_delay}ms (very polite)")
    Logger.info("   Socket timeout: #{div(@socket_timeout, 1000)}s")
    Logger.info("   Cache TTL: #{div(@cache_ttl, 86400)} days")

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call({:lookup, ip}, _from, state) do
    # Check cache first (with TTL check)
    case get_from_cache(ip) do
      {:ok, result} ->
        # Cache hit!
        new_state = %{state |
          total_queries: state.total_queries + 1,
          cache_hits: state.cache_hits + 1
        }
        {:reply, {:ok, result}, new_state}

      :miss ->
        # Cache miss - query Team Cymru
        case query_cymru([ip]) do
          {:ok, results} ->
            result = Map.get(results, ip, %{asn: nil, org: nil, country: nil, prefix: nil})
            put_in_cache(ip, result)

            new_state = %{state |
              total_queries: state.total_queries + 1,
              cache_misses: state.cache_misses + 1,
              batch_count: state.batch_count + 1
            }

            {:reply, {:ok, result}, new_state}

          {:error, :timeout} ->
            Logger.warning("⏱️  Team Cymru timeout for #{ip}")
            new_state = %{state |
              total_queries: state.total_queries + 1,
              timeouts: state.timeouts + 1
            }
            {:reply, {:ok, %{asn: nil, org: nil, country: nil, prefix: nil}}, new_state}

          {:error, reason} ->
            Logger.warning("⚠️  BGP query failed: #{inspect(reason)}")
            new_state = %{state | total_queries: state.total_queries + 1}
            {:reply, {:error, reason}, new_state}
        end
    end
  end

  @impl true
  def handle_call({:lookup_batch, ips}, _from, state) do
    # Separate cached and uncached IPs
    {cached, uncached} = Enum.reduce(ips, {%{}, []}, fn ip, {cache_acc, uncache_acc} ->
      case get_from_cache(ip) do
        {:ok, result} ->
          {Map.put(cache_acc, ip, result), uncache_acc}
        :miss ->
          {cache_acc, [ip | uncache_acc]}
      end
    end)

    # Query uncached IPs in batches
    queried_results = if uncached == [] do
      %{}
    else
      case query_cymru_batched(uncached) do
        {:ok, results} ->
          # Cache the results
          Enum.each(results, fn {ip, result} ->
            put_in_cache(ip, result)
          end)
          results

        {:error, :timeout} ->
          Logger.warning("⏱️  Team Cymru batch timeout (#{length(uncached)} IPs)")
          # Return empty results for timeout - pipeline will handle as failures
          Enum.reduce(uncached, %{}, fn ip, acc ->
            Map.put(acc, ip, %{asn: nil, org: nil, country: nil, prefix: nil})
          end)

        {:error, _reason} ->
          # Return empty results for errors
          Enum.reduce(uncached, %{}, fn ip, acc ->
            Map.put(acc, ip, %{asn: nil, org: nil, country: nil, prefix: nil})
          end)
      end
    end

    # Merge cached and queried results
    all_results = Map.merge(cached, queried_results)

    timeout_count = if match?({:error, :timeout}, query_cymru_batched(uncached)), do: 1, else: 0

    new_state = %{state |
      total_queries: state.total_queries + length(ips),
      cache_hits: state.cache_hits + map_size(cached),
      cache_misses: state.cache_misses + length(uncached),
      batch_count: state.batch_count + div(length(uncached) + @batch_size - 1, @batch_size),
      timeouts: state.timeouts + timeout_count
    }

    {:reply, {:ok, all_results}, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time

    cache_hit_rate = if state.total_queries > 0 do
      Float.round(state.cache_hits / state.total_queries * 100, 1)
    else
      0.0
    end

    stats = %{
      total_queries: state.total_queries,
      cache_hits: state.cache_hits,
      cache_misses: state.cache_misses,
      cache_hit_rate: cache_hit_rate,
      batch_count: state.batch_count,
      timeouts: state.timeouts,
      uptime_seconds: uptime,
      queries_per_sec: if uptime > 0 do
        Float.round(state.total_queries / uptime, 2)
      else
        0.0
      end,
      cache_size: :ets.info(:bgp_ip_cache, :size)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    # Clean up expired cache entries
    now = System.system_time(:second)
    cutoff = now - @cache_ttl

    # Delete entries older than TTL
    deleted = :ets.select_delete(:bgp_ip_cache, [
      {{:"$1", {:"$2", :"$3"}}, [{:<, :"$3", cutoff}], [true]}
    ])

    if deleted > 0 do
      Logger.debug("🧹 BGP Cache: Cleaned #{deleted} expired entries (>14 days old)")
    end

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, state}
  end

  # ============================================================================
  # CACHE HELPERS
  # ============================================================================

  defp get_from_cache(ip) do
    case :ets.lookup(:bgp_ip_cache, ip) do
      [{^ip, {result, timestamp}}] ->
        # Check if expired
        now = System.system_time(:second)
        if now - timestamp < @cache_ttl do
          {:ok, result}
        else
          # Expired - treat as miss
          :ets.delete(:bgp_ip_cache, ip)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp put_in_cache(ip, result) do
    timestamp = System.system_time(:second)
    :ets.insert(:bgp_ip_cache, {ip, {result, timestamp}})
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_cache, @cleanup_interval)
  end

  # ============================================================================
  # TEAM CYMRU WHOIS QUERY
  # ============================================================================

  defp query_cymru(ips) when is_list(ips) do
    # Build query in Team Cymru format
    query =
      "begin\n" <>
      "verbose\n" <>
      Enum.map_join(ips, "\n", & &1) <>
      "\nend\n"

    case :gen_tcp.connect(@cymru_host, @cymru_port, [:binary, active: false], @socket_timeout) do
      {:ok, socket} ->
        :ok = :gen_tcp.send(socket, query)

        case receive_response(socket, "") do
          {:ok, response} ->
            :gen_tcp.close(socket)
            {:ok, parse_cymru_response(response, ips)}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_cymru_batched(ips) do
    ips
    |> Enum.chunk_every(@batch_size)
    |> Enum.reduce({:ok, %{}}, fn batch, {:ok, acc} ->
      case query_cymru(batch) do
        {:ok, results} ->
          Process.sleep(@batch_delay)
          {:ok, Map.merge(acc, results)}

        {:error, :timeout} ->
          Logger.warning("⏱️  Team Cymru batch timeout (#{length(batch)} IPs)")
          # Continue processing, just mark these as failed
          empty_results = Enum.reduce(batch, %{}, fn ip, map_acc ->
            Map.put(map_acc, ip, %{asn: nil, org: nil, country: nil, prefix: nil})
          end)
          Process.sleep(@batch_delay)
          {:ok, Map.merge(acc, empty_results)}

        {:error, reason} ->
          Logger.warning("⚠️  BGP batch query failed: #{inspect(reason)}")
          # Continue processing, mark as failed
          empty_results = Enum.reduce(batch, %{}, fn ip, map_acc ->
            Map.put(map_acc, ip, %{asn: nil, org: nil, country: nil, prefix: nil})
          end)
          Process.sleep(@batch_delay)
          {:ok, Map.merge(acc, empty_results)}
      end
    end)
  end

  defp receive_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, @socket_timeout) do
      {:ok, data} ->
        receive_response(socket, acc <> data)

      {:error, :closed} ->
        {:ok, acc}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_cymru_response(response, ips) do
    response
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case parse_cymru_line(line) do
        {:ok, ip, asn, prefix, country, org} ->
          Map.put(acc, ip, %{
            asn: asn,
            org: org,
            country: country,
            prefix: prefix
          })

        :skip ->
          acc
      end
    end)
    |> then(fn results ->
      # Fill in missing IPs with nil results
      Enum.reduce(ips, results, fn ip, acc ->
        if Map.has_key?(acc, ip) do
          acc
        else
          Map.put(acc, ip, %{asn: nil, org: nil, country: nil, prefix: nil})
        end
      end)
    end)
  end

  defp parse_cymru_line(line) do
    # Format: "AS      | IP               | BGP Prefix          | CC | Registry | Allocated  | AS Name"
    # Example: "15169   | 8.8.8.8          | 8.8.8.0/24          | US | arin     | 1992-12-01 | GOOGLE, US"

    parts = String.split(line, "|") |> Enum.map(&String.trim/1)

    case parts do
      [asn, ip, prefix, country, _registry, _allocated | org_parts] when asn != "AS" ->
        org = Enum.join(org_parts, "|") |> String.trim()
        {:ok, ip, asn, prefix, country, org}

      _ ->
        :skip
    end
  end
end
