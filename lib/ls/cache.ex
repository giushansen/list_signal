defmodule LS.Cache do
  @moduledoc "ETS caches: CTL 5M dedup, HTTP politeness, BGP IP→ASN, RDAP domain→data. No DNS cache."

  use GenServer
  require Logger

  @cache_ttl 1_209_600          # 14 days for HTTP/BGP
  @rdap_cache_ttl 7_776_000     # 90 days for RDAP (registration data is very stable)
  @cleanup_interval 21_600_000  # 6 hours
  @ctl_cache :ctl_cache
  @http_cache :http_cache
  @bgp_cache :bgp_cache
  @rdap_cache :rdap_cache

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@ctl_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    :ets.new(@http_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    :ets.new(@bgp_cache, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@rdap_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    # Lock-free hit/miss counters: [http_hit, http_miss, bgp_hit, bgp_miss, rdap_hit, rdap_miss].
    # Feeds the admin dashboard's per-worker cache hit-ratio (are we re-fetching or reusing?).
    :persistent_term.put({__MODULE__, :counters}, :atomics.new(6, signed: false))
    schedule_cleanup()
    Logger.info("✅ Cache: CTL 5M + HTTP politeness + BGP IP→ASN + RDAP domains")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    cutoff = System.system_time(:second) - @cache_ttl
    rdap_cutoff = System.system_time(:second) - @rdap_cache_ttl
    ctl_del = (try do :ets.select_delete(@ctl_cache, [{{:"$1", {:"$2", :"$3", :"$4", :"$5"}}, [{:<, :"$5", cutoff}], [true]}]) rescue _ -> 0 end)
    http_del = (try do :ets.select_delete(@http_cache, [{{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}]) rescue _ -> 0 end)
    bgp_del = (try do :ets.select_delete(@bgp_cache, [{{:"$1", {:"$2", :"$3"}}, [{:<, :"$3", cutoff}], [true]}]) rescue _ -> 0 end)
    rdap_del = (try do :ets.select_delete(@rdap_cache, [{{:"$1", :"$2"}, [{:<, :"$2", rdap_cutoff}], [true]}]) rescue _ -> 0 end)
    total = ctl_del + http_del + bgp_del + rdap_del
    if total > 0, do: Logger.info("🧹 Cache cleanup: #{total} expired (CTL:#{ctl_del} HTTP:#{http_del} BGP:#{bgp_del} RDAP:#{rdap_del})")
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup_cache, @cleanup_interval)

  # === CTL (5M cap, FIFO eviction) ===
  @tracker_max_size 5_000_000
  @eviction_batch 250_000
  @platform_cert_rate 20.0
  @platform_subdomain_count 100
  @platform_min_time 3600

  @doc """
  Track a domain seen in a CT log. Returns `:new` on first sighting (the
  caller then enqueues it for enrichment) or `:tracked` on a repeat (dedup —
  this cache is why the same cert seen across 8 CT logs enriches once).
  Bounded at 5M entries; FIFO-evicts the 250K least-recently-seen when full.
  """
  def ctl_track(domain, subdomain_count) do
    now = System.system_time(:second)
    case :ets.lookup(@ctl_cache, domain) do
      [{^domain, {cc, max_sc, fs, _ls}}] ->
        :ets.insert(@ctl_cache, {domain, {cc + 1, max(max_sc, subdomain_count), fs, now}})
        :tracked
      [] ->
        if :ets.info(@ctl_cache, :size) >= @tracker_max_size, do: ctl_evict()
        :ets.insert(@ctl_cache, {domain, {1, subdomain_count, now, now}})
        :new
    end
  end

  @doc """
  Heuristic: is this a SaaS/hosting platform issuing certs for customers
  (≥20 certs/hour sustained, or ≥100 subdomains)? Platform apex domains are
  skipped by discovery — their subdomains are the interesting part.
  """
  def ctl_is_platform?(domain) do
    case :ets.lookup(@ctl_cache, domain) do
      [{^domain, {cc, sc, fs, _ls}}] ->
        now = System.system_time(:second)
        hours = max((now - fs) / 3600.0, 0.01)
        (now - fs) >= @platform_min_time and (cc / hours >= @platform_cert_rate or sc >= @platform_subdomain_count)
      [] -> false
    end
  end

  def ctl_cert_count(domain) do
    case :ets.lookup(@ctl_cache, domain) do [{^domain, {cc, _, _, _}}] -> cc; [] -> 0 end
  end

  def ctl_stats do
    size = :ets.info(@ctl_cache, :size)
    mem = Float.round((:ets.info(@ctl_cache, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1)
    %{entries: size, memory_mb: mem, max_size: @tracker_max_size, usage_pct: Float.round(size / @tracker_max_size * 100, 1)}
  end

  defp ctl_evict do
    :ets.tab2list(@ctl_cache)
    |> Enum.sort_by(fn {_, {_, _, _, ls}} -> ls end) |> Enum.take(@eviction_batch)
    |> Enum.each(fn {d, _} -> :ets.delete(@ctl_cache, d) end)
    Logger.info("🧹 CTL eviction: dropped #{@eviction_batch} oldest")
  end

  # hit_idx/miss_idx per cache in the atomics vector
  defp bump(idx) do
    case :persistent_term.get({__MODULE__, :counters}, nil) do
      nil -> :ok
      ref -> :atomics.add(ref, idx, 1)
    end
  end

  # === HTTP ===
  def http_lookup(domain) do
    case :ets.lookup(@http_cache, domain) do
      [{_, _}] -> bump(1); :hit
      [] -> bump(2); :miss
    end
  end
  def http_insert(domain), do: :ets.insert(@http_cache, {domain, System.system_time(:second)})

  # === BGP ===
  def bgp_lookup(ip) do
    case :ets.lookup(@bgp_cache, ip) do
      [{^ip, {result, _}}] -> bump(3); {:hit, result}
      [] -> bump(4); :miss
    end
  end
  def bgp_insert(ip, result), do: :ets.insert(@bgp_cache, {ip, {result, System.system_time(:second)}})

  # === RDAP (90-day TTL) ===
  def rdap_lookup(domain) do
    case :ets.lookup(@rdap_cache, domain) do
      [{_, _}] -> bump(5); :hit
      [] -> bump(6); :miss
    end
  end
  def rdap_insert(domain), do: :ets.insert(@rdap_cache, {domain, System.system_time(:second)})

  # === DNS stubs ===
  def dns_lookup(_), do: :miss
  def dns_insert(_), do: :ok

  # === Stats ===
  def stats do
    mem_fn = fn t -> Float.round((:ets.info(t, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1) end
    {hh, hm, bh, bm, rh, rm} = counters()
    %{
      ctl: ctl_stats(),
      http: %{entries: :ets.info(@http_cache, :size), memory_mb: mem_fn.(@http_cache), hits: hh, misses: hm},
      bgp: %{entries: :ets.info(@bgp_cache, :size), memory_mb: mem_fn.(@bgp_cache), hits: bh, misses: bm},
      rdap: %{entries: :ets.info(@rdap_cache, :size), memory_mb: mem_fn.(@rdap_cache), hits: rh, misses: rm}
    }
  end

  defp counters do
    case :persistent_term.get({__MODULE__, :counters}, nil) do
      nil -> {0, 0, 0, 0, 0, 0}
      ref -> {:atomics.get(ref, 1), :atomics.get(ref, 2), :atomics.get(ref, 3),
              :atomics.get(ref, 4), :atomics.get(ref, 5), :atomics.get(ref, 6)}
    end
  end
end
