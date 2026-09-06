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

  ## Eviction never copies the table (2026-09-06)

  The first version of `evict_to/3` did `:ets.tab2list/1` + `Enum.sort_by/2`
  on the whole table, inside whichever process happened to insert the entry
  that crossed the cap. On the master that table is the 5M-entry CT dedup
  cache and the inserting processes are the ~28 CT poller workers, which all
  cross the cap within the same second. Each one materialised a 5M-row list
  (~600 MB) and then sorted it: the BEAM went from 2.1 GB to 11.9 GB in 40
  seconds and the watchdog restarted the site. This was the "unexplained"
  ~7 GB spike behind every master restart since 2026-08-21 (14 restarts);
  the forensics trap on 2026-09-06 02:30 caught the workers red-handed, and
  the `ops_memory_snapshots` timeline shows `ctl_cache` at exactly 5,000,000
  rows at the start of every spike.

  Now eviction (a) samples 20K rows to find the age cutoff, (b) deletes with
  `:ets.select_delete/2`, which runs inside ETS and copies nothing into the
  caller, and (c) is single-flight per table, so concurrent inserters skip
  instead of evicting the same tail 28 times over. Peak caller memory is a
  few MB regardless of table size; `test/ls/cache_bounds_test.exs` pins it
  with a hard heap cap.
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

  # Row pattern per table with the age (unix seconds) bound to $1 and the key
  # to $2. ONE place, used by both the TTL cleanup and the cap eviction, so
  # the two can never disagree about where the timestamp lives in a row.
  @age_specs %{
    @ctl_cache => {:"$2", {:_, :_, :_, :"$1"}},
    @http_cache => {:"$2", :"$1"},
    @bgp_cache => {:"$2", {:_, :"$1"}},
    @rdap_cache => {:"$2", :"$1"}
  }
  # Rows sampled to estimate the age cutoff. A `set` table is traversed in
  # hash order, which is independent of insertion time, so the first N rows
  # are an unbiased sample of ages. 20K keeps the quantile error under ~1%.
  @evict_sample 20_000
  @evict_locks :ls_cache_evict_locks

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@ctl_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    :ets.new(@http_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    :ets.new(@bgp_cache, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(@rdap_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    ensure_lock_table()
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
    ctl_del = delete_older_than(@ctl_cache, cutoff)
    http_del = delete_older_than(@http_cache, cutoff)
    bgp_del = delete_older_than(@bgp_cache, cutoff)
    rdap_del = delete_older_than(@rdap_cache, rdap_cutoff)
    total = ctl_del + http_del + bgp_del + rdap_del
    if total > 0, do: Logger.info("🧹 Cache cleanup: #{total} expired (CTL:#{ctl_del} HTTP:#{http_del} BGP:#{bgp_del} RDAP:#{rdap_del})")
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup_cache, @cleanup_interval)

  defp delete_older_than(table, cutoff) do
    :ets.select_delete(table, [{Map.fetch!(@age_specs, table), [{:<, :"$1", cutoff}], [true]}])
  rescue
    _ -> 0
  end

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
    dropped = evict_to(@ctl_cache, keep, Map.fetch!(@age_specs, @ctl_cache))
    if dropped > 0, do: Logger.info("🧹 CTL eviction: dropped #{dropped} oldest")
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
  defp bounded_insert(table, row, name) do
    cap = cap_for(name)

    if is_integer(:ets.info(table, :size)) and :ets.info(table, :size) >= cap do
      dropped = evict_to(table, trunc(cap * @evict_to_fraction), Map.fetch!(@age_specs, table))
      if dropped > 0, do: Logger.info("🧹 #{name} cache at cap #{cap}: dropped #{dropped} coldest")
    end

    :ets.insert(table, row)
  end

  @doc false
  # Drop entries oldest-first until the table holds at most `keep`. Returns the
  # number dropped (0 when another process is already evicting this table).
  # Oldest-first is what makes a size cap safe for politeness: the recent
  # window survives, only the cold tail goes.
  #
  # `age_spec` is an ETS match pattern for one row with the age bound to $1
  # and the key to $2 (see @age_specs). The cutoff comes from a bounded
  # sample and the delete runs inside ETS, so the caller's heap stays flat
  # however large the table: the tab2list version of this function is what
  # blew the master up (moduledoc, 2026-09-06).
  def evict_to(table, keep, age_spec) when is_tuple(age_spec) do
    # :ets.info/2 returns :undefined (not an error) for a missing table — a
    # table can legitimately be absent on a node that does not run that lane.
    size =
      case :ets.info(table, :size) do
        n when is_integer(n) -> n
        _ -> 0
      end

    excess = size - keep

    cond do
      excess <= 0 ->
        0

      not lock_evict(table) ->
        0

      true ->
        try do
          cutoff = age_cutoff(table, age_spec, excess / size)
          # Strictly older than the cutoff first; then only as many rows AT
          # the cutoff as still needed. Ages are whole seconds, so a burst of
          # inserts shares one age and "everything =< cutoff" would empty the
          # table, i.e. drop the recent window politeness depends on.
          dropped = :ets.select_delete(table, [{age_spec, [{:<, :"$1", cutoff}], [true]}])
          dropped + delete_at_age(table, age_spec, cutoff, excess - dropped)
        after
          unlock_evict(table)
        end
    end
  rescue
    ArgumentError -> 0
  end

  defp delete_at_age(_table, _spec, _age, need) when need <= 0, do: 0

  defp delete_at_age(table, age_spec, age, need) do
    case :ets.select(table, [{age_spec, [{:==, :"$1", age}], [:"$2"]}], need) do
      {keys, _cont} ->
        Enum.each(keys, &:ets.delete(table, &1))
        length(keys)

      :"$end_of_table" ->
        0
    end
  end

  # The age below which `fraction` of the table falls, from a sample.
  defp age_cutoff(table, age_spec, fraction) do
    ages =
      case :ets.select(table, [{age_spec, [], [:"$1"]}], @evict_sample) do
        {ages, _cont} -> Enum.sort(ages)
        :"$end_of_table" -> []
      end

    case ages do
      [] -> 0
      _ -> Enum.at(ages, min(max(ceil(fraction * length(ages)) - 1, 0), length(ages) - 1))
    end
  end

  # Single-flight per table. A lock held by a dead process is stale and is
  # taken over; a live holder means "someone is already on it, insert and
  # move on" — a few hundred entries of overshoot beats N copies of the work.
  @doc false
  def evict_lock_table, do: @evict_locks

  defp lock_evict(table) do
    ensure_lock_table()

    case :ets.insert_new(@evict_locks, {table, self()}) do
      true ->
        true

      false ->
        case :ets.lookup(@evict_locks, table) do
          [{^table, pid}] when pid != self() ->
            if Process.alive?(pid) do
              false
            else
              :ets.delete_object(@evict_locks, {table, pid})
              :ets.insert_new(@evict_locks, {table, self()})
            end

          _ ->
            :ets.insert_new(@evict_locks, {table, self()})
        end
    end
  end

  defp unlock_evict(table), do: :ets.delete_object(@evict_locks, {table, self()})

  # Owned by LS.Cache when it is running; created on demand otherwise (tests,
  # nodes where the lane's cache exists but the GenServer does not).
  defp ensure_lock_table do
    if :ets.info(@evict_locks) == :undefined do
      :ets.new(@evict_locks, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
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
    do: bounded_insert(@http_cache, {domain, System.system_time(:second)}, :http)

  # === BGP ===
  def bgp_lookup(ip) do
    case :ets.lookup(@bgp_cache, ip) do
      [{^ip, {result, _}}] -> bump(3); {:hit, result}
      [] -> bump(4); :miss
    end
  end
  def bgp_insert(ip, result),
    do: bounded_insert(@bgp_cache, {ip, {result, System.system_time(:second)}}, :bgp)

  # === RDAP (90-day TTL) ===
  def rdap_lookup(domain) do
    case :ets.lookup(@rdap_cache, domain) do
      [{_, _}] -> bump(5); :hit
      [] -> bump(6); :miss
    end
  end
  def rdap_insert(domain),
    do: bounded_insert(@rdap_cache, {domain, System.system_time(:second)}, :rdap)

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
