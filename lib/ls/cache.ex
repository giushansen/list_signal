defmodule LS.Cache do
  @moduledoc """
  ETS caches: CTL dedup, HTTP politeness, BGP IP→ASN, RDAP domain→data.

  ## Every cache is bounded by SIZE as well as by TTL (2026-08-26)

  The HTTP, BGP and RDAP caches were bounded only by their TTL — 14 days for
  HTTP/BGP, 90 days for RDAP — so nothing was evicted until an entry was two
  weeks old, and the tables simply grew until then. Measured on a worker:
  ~9,800 new HTTP entries and ~6,450 RDAP entries per hour, which projects to
  ~3.3M and ~14M entries, roughly **1.7 GB of ETS on nodes that have 2-4 GB of
  RAM in total**. The BEAM paged that into swap, which is why long-running
  workers drifted to ~250 MB available and swapped thousands of pages a second
  while a freshly restarted one sat at ~1.9 GB free. The owner was told to
  "redeploy periodically" — that was treating the symptom.

  Each cache now has a size cap derived from the node's own RAM, with
  oldest-first eviction (`evict_to/3`). This does NOT loosen politeness: the
  cap only ever drops the COLDEST entries, so the recent window that politeness
  actually depends on is exactly what survives. The per-IP rate limiter is
  untouched.

  Caps are deliberately generous relative to usefulness — measured hit rates
  are ~0.2% (the CT firehose is mostly first-sight domains), so the cold tail
  was costing gigabytes to serve almost nothing.
  """

  use GenServer
  require Logger

  @cache_ttl 1_209_600          # 14 days for HTTP/BGP
  @rdap_cache_ttl 7_776_000     # 90 days for RDAP (registration data is very stable)
  @cleanup_interval 21_600_000  # 6 hours

  # Share of the node's RAM these caches may occupy in total. ~110 bytes per
  # entry measured on prod (2.5 MB / 26,389 HTTP rows).
  @cache_budget_pct 5
  @bytes_per_entry 110
  # Split of that budget. RDAP and HTTP carry one row per domain seen; BGP is
  # per-IP, so far fewer distinct keys.
  @split %{http: 0.40, rdap: 0.40, bgp: 0.20}
  # Fallback when /proc/meminfo is unreadable (dev laptop, container).
  @default_total_mb 2_048
  # Evict down to this fraction of the cap, so eviction runs once per ~10% of
  # cap inserts rather than on every insert once full.
  @evict_to_fraction 0.9
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
    caps = compute_caps(total_ram_mb())
    :persistent_term.put({__MODULE__, :caps}, caps)
    schedule_cleanup()

    Logger.info(
      "✅ Cache: CTL 5M + bounded HTTP #{caps.http} / RDAP #{caps.rdap} / BGP #{caps.bgp} entries " <>
        "(#{total_ram_mb()}MB node)"
    )
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
    keep = max(:ets.info(@ctl_cache, :size) - @eviction_batch, 0)
    dropped = evict_to(@ctl_cache, keep, fn {_, {_, _, _, ls}} -> ls end)
    Logger.info("🧹 CTL eviction: dropped #{dropped} oldest")
  end

  # ── Size bounds (see the moduledoc) ────────────────────────────────────

  @doc """
  Entry caps for this node, derived from its RAM. Pure, so the sizing is
  testable without a machine of each size.
  """
  @spec compute_caps(pos_integer()) :: %{http: pos_integer(), bgp: pos_integer(), rdap: pos_integer()}
  def compute_caps(total_mb) when is_integer(total_mb) and total_mb > 0 do
    budget_entries = div(total_mb * @cache_budget_pct * 1_048_576, 100 * @bytes_per_entry)

    Map.new(@split, fn {name, share} ->
      # Never below 50k: a cache too small to hold the recent window would make
      # us re-fetch domains we just fetched, which is the opposite of politeness.
      {name, max(50_000, trunc(budget_entries * share))}
    end)
  end

  def compute_caps(_), do: compute_caps(@default_total_mb)

  @doc "This node's RAM in MB, `@default_total_mb` where /proc is unavailable."
  def total_ram_mb do
    with {:ok, s} <- File.read("/proc/meminfo"),
         [_, kb] <- Regex.run(~r/^MemTotal:\s+(\d+)/m, s) do
      div(String.to_integer(kb), 1024)
    else
      _ -> @default_total_mb
    end
  end

  defp cap_for(name) do
    case :persistent_term.get({__MODULE__, :caps}, nil) do
      %{^name => cap} -> cap
      _ -> Map.fetch!(compute_caps(@default_total_mb), name)
    end
  end

  # Insert, evicting the coldest entries first when the table is at its cap.
  defp bounded_insert(table, row, name, age_fn) do
    cap = cap_for(name)

    if is_integer(:ets.info(table, :size)) and :ets.info(table, :size) >= cap do
      dropped = evict_to(table, trunc(cap * @evict_to_fraction), age_fn)
      Logger.info("🧹 #{name} cache at cap #{cap}: dropped #{dropped} coldest")
    end

    :ets.insert(table, row)
  end

  @doc false
  # Drop entries oldest-first until the table holds at most `keep`. Returns the
  # number dropped. Oldest-first is what makes a size cap safe for politeness:
  # the recent window survives, only the cold tail goes.
  def evict_to(table, keep, age_fn) do
    # :ets.info/2 returns :undefined (not an error) for a missing table — a
    # table can legitimately be absent on a node that does not run that lane.
    excess =
      case :ets.info(table, :size) do
        n when is_integer(n) -> n - keep
        _ -> 0
      end

    if excess > 0 do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(age_fn)
      |> Enum.take(excess)
      |> Enum.each(fn row -> :ets.delete(table, elem(row, 0)) end)

      excess
    else
      0
    end
  rescue
    ArgumentError -> 0
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
  def http_insert(domain),
    do: bounded_insert(@http_cache, {domain, System.system_time(:second)}, :http, &elem(&1, 1))

  # === BGP ===
  def bgp_lookup(ip) do
    case :ets.lookup(@bgp_cache, ip) do
      [{^ip, {result, _}}] -> bump(3); {:hit, result}
      [] -> bump(4); :miss
    end
  end
  def bgp_insert(ip, result),
    do: bounded_insert(@bgp_cache, {ip, {result, System.system_time(:second)}}, :bgp, &elem(elem(&1, 1), 1))

  # === RDAP (90-day TTL) ===
  def rdap_lookup(domain) do
    case :ets.lookup(@rdap_cache, domain) do
      [{_, _}] -> bump(5); :hit
      [] -> bump(6); :miss
    end
  end
  def rdap_insert(domain),
    do: bounded_insert(@rdap_cache, {domain, System.system_time(:second)}, :rdap, &elem(&1, 1))

  # === DNS stubs ===
  def dns_lookup(_), do: :miss
  def dns_insert(_), do: :ok

  # === Stats ===
  def stats do
    mem_fn = fn t -> Float.round((:ets.info(t, :memory) || 0) * :erlang.system_info(:wordsize) / 1_048_576, 1) end
    {hh, hm, bh, bm, rh, rm} = counters()
    %{
      ctl: ctl_stats(),
      http: %{entries: :ets.info(@http_cache, :size), memory_mb: mem_fn.(@http_cache), hits: hh, misses: hm, max_size: cap_for(:http)},
      bgp: %{entries: :ets.info(@bgp_cache, :size), memory_mb: mem_fn.(@bgp_cache), hits: bh, misses: bm, max_size: cap_for(:bgp)},
      rdap: %{entries: :ets.info(@rdap_cache, :size), memory_mb: mem_fn.(@rdap_cache), hits: rh, misses: rm, max_size: cap_for(:rdap)}
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
