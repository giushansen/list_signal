defmodule LS.Cluster.WorkerAgent do
  @moduledoc """
  Worker agent — pulls batches, enriches domains, returns rows to master.

  ## Pipeline per batch

      1. DNS  (all domains, 500 concurrent)
      2. Parallel:
         a. HTTP  (filtered, 100 concurrent — the bottleneck)
         b. BGP   (batched via Team Cymru)
         c. RDAP  (cache-filtered, 3 concurrent, per-server rate limited)
      3. Reputation lookups at merge time (pure ETS reads):
         - Tranco rank, Majestic rank + RefSubNets
         - Blocklist flags (malware/phishing/disposable)
      4. Merge -> return rows to master
  """

  use GenServer
  require Logger

  alias LS.HTTP.DomainFilter
  alias LS.BGP.Resolver, as: BGPResolver
  alias LS.RDAP.Client, as: RDAPClient
  alias LS.Reputation.Blocklist
  alias LS.Cache

  @reconnect_interval_ms 10_000
  @empty_queue_wait_ms 30_000
  @max_errors 50

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Live throughput and state snapshot for this worker.

  Includes connection state, totals, `domains_per_sec`, per-stage timings of
  the last batch (`last_stages`) and the configured concurrencies
  (`LS_HTTP_CONCURRENCY` etc.). Called cross-node by the admin dashboard.
  """
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc """
  Graceful-deploy mode: finish the in-flight batch, pull no new work.

  Poll `drain_status/0` until `idle: true`, then it is safe to stop the node
  without requeueing (the master would otherwise requeue the batch after its
  10-minute in-flight timeout).
  """
  @spec drain() :: :ok
  def drain, do: GenServer.cast(__MODULE__, :drain)

  @doc "`%{draining: bool, idle: bool}` — `idle: true` means safe to stop."
  @spec drain_status() :: %{draining: boolean(), idle: boolean()}
  def drain_status, do: GenServer.call(__MODULE__, :drain_status)

  @impl true
  def init(_opts) do
    master = System.get_env("LS_MASTER", "master@10.0.0.1") |> String.to_atom()
    http_c = System.get_env("LS_HTTP_CONCURRENCY", "100") |> String.to_integer()
    dns_c = System.get_env("LS_DNS_CONCURRENCY", "500") |> String.to_integer()
    rdap_c = System.get_env("LS_RDAP_CONCURRENCY", "3") |> String.to_integer()
    batch = System.get_env("LS_BATCH_SIZE", "1000") |> String.to_integer()
    LS.HTTP.DomainFilter.load_tlds()
    state = %{
      master_node: master, connected: false,
      http_concurrency: http_c, dns_concurrency: dns_c,
      rdap_concurrency: rdap_c, batch_size: batch,
      total_enriched: 0, total_batches: 0, current_batch: nil, draining: false,
      inflight: 0, max_inflight: parallel_batches(),
      # Share of dequeued names that become HTTP candidates, learned from
      # each batch; sizes the next dequeue (dequeue_size/3). 0.4 is the
      # 2026-10-24 fleet average (290-620 of 1,000).
      cand_ratio: 0.4,
      start_time: System.monotonic_time(:second),
      last_stages: nil, last_samples: %{}, errors: []
    }
    send(self(), :connect_and_work)
    Logger.info("WorkerAgent (master: #{master}, batch: #{batch}, HTTP: #{http_c}, DNS: #{dns_c}, RDAP: #{rdap_c})")
    {:ok, state}
  end

  # ==========================================================================
  # STATS
  # ==========================================================================

  @impl true
  def handle_call(:stats, _from, s) do
    up = System.monotonic_time(:second) - s.start_time
    {:reply, %{
      connected: s.connected, master_node: s.master_node,
      total_enriched: s.total_enriched, total_batches: s.total_batches,
      current_batch: s.current_batch,
      domains_per_sec: if(up > 0, do: Float.round(s.total_enriched / up, 1), else: 0.0),
      http_concurrency: s.http_concurrency, dns_concurrency: s.dns_concurrency,
      rdap_concurrency: s.rdap_concurrency, batch_size: s.batch_size,
      last_stages: s.last_stages, error_count: length(s.errors),
      uptime_seconds: up
    }, s}
  end

  @impl true
  def handle_call(:detailed_stats, _from, s) do
    {:reply, %{
      stats: elem(handle_call(:stats, nil, s), 1),
      samples: s.last_samples, errors: s.errors
    }, s}
  end

  @impl true
  def handle_call({:peek, stage}, _from, s) do
    {:reply, Map.get(s.last_samples, stage, []), s}
  end

  @impl true
  def handle_call(:errors, _from, s), do: {:reply, s.errors, s}

  # ==========================================================================
  # DRAIN (graceful deploy — finish in-flight batch, pull no new work)
  # ==========================================================================

  @impl true
  def handle_call(:drain_status, _from, s) do
    {:reply, %{draining: s.draining, idle: s.inflight == 0}, s}
  end

  @impl true
  def handle_cast(:drain, s) do
    Logger.info("WorkerAgent draining — no new batches")
    {:noreply, %{s | draining: true}}
  end

  # ==========================================================================
  # CONNECTION
  # ==========================================================================

  @impl true
  def handle_info(:connect_and_work, s) do
    case Node.ping(s.master_node) do
      :pong ->
        Logger.info("Connected to master #{s.master_node}")
        send(self(), :pull_work)
        {:noreply, %{s | connected: true}}
      :pang ->
        Logger.warning("Cannot reach master #{s.master_node}, retry #{div(@reconnect_interval_ms, 1000)}s")
        Process.send_after(self(), :connect_and_work, @reconnect_interval_ms)
        {:noreply, %{s | connected: false}}
    end
  end

  # ==========================================================================
  # WORK LOOP
  # ==========================================================================

  # One batch at a time left the node's fetch budget idle a third of the
  # time (2026-10-03, measured on ny1 and chi1): DNS 15 s, then the HTTP
  # stage at the budget cap for 150-240 s, then merge and ML for 18-58 s
  # with no fetch in flight. A second batch, staggered by half a minute,
  # fills the gaps; the node budget (LS.HTTP.NodeBudget) is node-wide, so
  # two batches can never exceed the per-IP ceiling, and each batch takes
  # half the DNS concurrency so the resolver load is unchanged. A node with
  # under 3.5 GB runs one batch; `LS_WORKER_BATCHES` overrides; a second
  # batch is not started under 700 MB of available memory.
  @stagger_ms 30_000
  @min_avail_mb 700

  @impl true
  def handle_info(:pull_work, s) when s.inflight >= s.max_inflight, do: {:noreply, s}

  def handle_info(:pull_work, s) do
    if s.inflight > 0 and not memory_headroom?() do
      Process.send_after(self(), :pull_work, @stagger_ms)
      {:noreply, s}
    else
      s = start_batch(s)
      if s.inflight < s.max_inflight and not s.draining, do: Process.send_after(self(), :pull_work, @stagger_ms)
      {:noreply, s}
    end
  end

  @impl true
  def handle_info({:batch_done, bid, results, stages, samples, batch_errors, skipped}, s) do
    queue = {LS.Cluster.WorkQueue, s.master_node}
    cyc = Map.get(stages, :cycle_ms, 0)
    known = stages.dns.ms + max(stages.http.ms, max(stages.bgp.ms, stages.rdap.ms)) + get_in(stages, [:merge, :ms])
    Logger.info("Batch #{bid}: #{length(results)} rows (DNS:#{stages.dns.ms}ms HTTP:#{stages.http.ms}ms BGP:#{stages.bgp.ms}ms RDAP:#{stages.rdap.ms}ms MERGE:#{get_in(stages, [:merge, :ms])}ms (ML:#{:persistent_term.get({__MODULE__, :last_ml_ms}, 0)}ms) | cycle #{cyc}ms, unaccounted #{max(cyc - known, 0)}ms | cands #{stages.http.input} cap #{stages.http[:cap]} surplus #{stages.http[:surplus]} cut #{stages.http[:cut]})")
    # The verdicts travel with the rows so the gate can remember them
    # (LS.Cluster.WorkQueue.complete/3): what was filtered writes no row.
    GenServer.cast(queue, {:complete, bid, results, Map.take(skipped, [:dormant, :soft, :recent, :unresolved, :unresolved_refresh])})
    # Per-address provenance and people (2026-10-26) go to the child tables
    # on the master, separate from the row so the Inserter is untouched.
    GenServer.cast(queue, {:child_rows, Map.get(skipped, :child_rows, %{})})
    # What this batch could not fetch goes back: untouched surplus to the
    # front, deadline-cut candidates to the tail (2026-10-24).
    LS.Cluster.WorkQueue.requeue(queue, Map.get(skipped, :returned_front, []), :front)
    LS.Cluster.WorkQueue.requeue(queue, Map.get(skipped, :returned_tail, []), :tail)
    errors = (batch_errors ++ s.errors) |> Enum.take(@max_errors)
    new_s = finished(%{s |
      total_enriched: s.total_enriched + length(results),
      total_batches: s.total_batches + 1,
      last_stages: stages,
      last_samples: samples,
      cand_ratio: Map.get(stages.http, :cand_ratio, s.cand_ratio),
      errors: errors
    })
    unless new_s.draining, do: send(self(), :pull_work)
    {:noreply, new_s}
  end

  @impl true
  def handle_info(:batch_empty, s) do
    unless s.draining, do: Process.send_after(self(), :pull_work, @empty_queue_wait_ms)
    {:noreply, finished(s)}
  end

  @impl true
  def handle_info({:batch_error, reason}, s) do
    err = %{time: now_iso(), msg: "Lost master: #{inspect(reason)}", stage: "connection"}
    errors = [err | s.errors] |> Enum.take(@max_errors)
    Process.send_after(self(), :connect_and_work, @reconnect_interval_ms)
    {:noreply, %{finished(s) | connected: false, errors: errors}}
  end

  @impl true
  def handle_info(_msg, s), do: {:noreply, s}

  # Every two minutes a running batch tells the master it is alive, so the
  # 10-minute in-flight timeout only fires for a dead worker (2026-10-24).
  @heartbeat_ms 120_000

  defp start_batch(s) do
    queue = {LS.Cluster.WorkQueue, s.master_node}
    parent = self()
    %{http_concurrency: hc, rdap_concurrency: rc, batch_size: bs} = s
    dc = max(div(s.dns_concurrency, s.max_inflight), 50)
    want = dequeue_size(http_candidate_cap(), s.cand_ratio, bs)
    spawn_link(fn ->
      try do
        case GenServer.call(queue, {:dequeue, want}, 15_000) do
          {:ok, bid, domains} ->
            Logger.info("Batch #{bid}: #{length(domains)} domains (asked #{want})")
            # apply_interval dies with this process, so a crashed batch
            # stops beating and the master requeues it as before.
            {:ok, beat} = :timer.apply_interval(@heartbeat_ms, GenServer, :cast, [queue, {:heartbeat, bid}])
            t0 = System.monotonic_time(:millisecond)
            {results, stages, samples, errors, skipped} = enrich_batch(domains, hc, dc, rc)
            :timer.cancel(beat)
            stages = Map.put(stages, :cycle_ms, System.monotonic_time(:millisecond) - t0)
            send(parent, {:batch_done, bid, results, stages, samples, errors, skipped})
          {:empty, []} ->
            send(parent, :batch_empty)
        end
      catch
        :exit, reason -> send(parent, {:batch_error, reason})
      end
    end)
    %{s | current_batch: :working, inflight: s.inflight + 1}
  end

  @doc false
  # Pure. How many batches this node runs at once.
  def parallel_batches(env \\ System.get_env("LS_WORKER_BATCHES"), mem_total_mb \\ meminfo_mb("MemTotal")) do
    case env && Integer.parse(env) do
      {n, _} when n in 1..4 -> n
      _ -> if mem_total_mb >= 3_500, do: 2, else: 1
    end
  end

  defp memory_headroom?, do: meminfo_mb("MemAvailable") >= @min_avail_mb

  defp meminfo_mb(key) do
    case File.read("/proc/meminfo") do
      {:ok, text} ->
        case Regex.run(~r/^#{key}:\s+(\d+) kB/m, text) do
          [_, kb] -> div(String.to_integer(kb), 1024)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp finished(s) do
    inflight = max(s.inflight - 1, 0)
    %{s | inflight: inflight, current_batch: if(inflight > 0, do: :working, else: nil)}
  end


  # ==========================================================================
  # ENRICHMENT
  # ==========================================================================

  # Await a stage task; on overrun, kill it and continue with empty results so
  # one slow stage can never take down the batch (reliability pillar).
  defp await_stage(task, stage, timeout_ms) do
    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, res} ->
        res

      _ ->
        require Logger
        Logger.error("#{stage} stage exceeded #{timeout_ms}ms — batch continues without it")
        %{}
    end
  end

  defp enrich_batch(domains, http_c, dns_c, rdap_c) do
    worker = Node.self() |> Atom.to_string()
    errors = []

    # 1. DNS (must complete before parallel stage)
    {dns_us, dns_results} = :timer.tc(fn -> enrich_dns(domains, dns_c) end)
    dns_to = length(domains) - map_size(dns_results)
    errors = if dns_to > 0 do
      [%{time: now_iso(), msg: "DNS: #{dns_to}/#{length(domains)} timed out", stage: "dns"} | errors]
    else
      errors
    end

    # 2. Classify
    issuers = Map.new(domains, fn d -> {d[:ctl_domain] || d[:domain], d[:ctl_issuer] || ""} end)
    refresh = refresh_set(domains)
    # The homepage simhash from the last check, for refresh items only, so
    # the HTTP stage can skip the secondary pages of an unchanged site.
    prev_simhash = for d <- domains, d[:source] == :recrawl, is_integer(d[:prev_simhash]), d[:prev_simhash] > 0, into: %{}, do: {d[:ctl_domain] || d[:domain], d[:prev_simhash]}
    {http_cands, bgp_cands, skipped} = classify(dns_results, issuers, refresh)
    # Only as many fetches as this batch's share of the node budget can
    # finish inside the master's in-flight window (2026-10-24). The surplus
    # goes back to the front of the queue untouched, see :batch_done.
    cap = http_candidate_cap()
    {http_cands, surplus} = split_candidates(http_cands, cap)
    cand_set = MapSet.new(http_cands, fn {d, _ip} -> d end)
    # RDAP is politeness-limited to 2/s: only for domains that get a row.
    rdap_cands = classify_rdap(dns_results) |> Enum.filter(&MapSet.member?(cand_set, &1))
    unresolved = for d <- domains, dom = d[:ctl_domain] || d[:domain], not Map.has_key?(dns_results, dom), do: dom
    # A refresh item whose name no longer resolves on this worker gets its
    # check recorded on the master (2026-10-26), see unresolved_refresh/3.
    skipped =
      skipped
      |> Map.put(:unresolved, unresolved)
      |> Map.put(:unresolved_refresh, unresolved_refresh(domains, dns_results, http_cands))

    # 3. Parallel: HTTP + BGP + RDAP
    http_task = Task.async(fn -> enrich_http(http_cands, http_c, prev_simhash) end)
    bgp_task = Task.async(fn -> enrich_bgp(bgp_cands) end)
    rdap_task = Task.async(fn -> enrich_rdap(rdap_cands, rdap_c) end)

    # RDAP is rate-limited (politeness), so its wall time scales with candidate
    # count — a fixed await here crash-looped h1 when batch_size=2000 pushed
    # RDAP past 120s (2026-07-27). Timeouts now scale, and an overrunning stage
    # is shut down and skipped instead of killing the whole batch (its domains
    # still get rows, just without that stage's fields).
    rdap_timeout = max(120_000, length(rdap_cands) * 1_000)
    # The HTTP stage is paced by the node budget (LS.HTTP.NodeBudget): with
    # 350 candidates at 140 a minute the stage legitimately runs 150 s, and
    # a fixed 120 s await killed it and threw every fetched page away
    # (2026-10-01 evening: "http stage exceeded 120000ms" four times an
    # hour per worker). The await now covers the paced duration plus slack.
    # enrich_http keeps what finished by its own deadline; the await here is
    # only the backstop for a stage that never returns.
    # The outer timer is a safety net for a hung stage, never the working
    # deadline: the stage keeps what finished by its own deadline and
    # returns, and shutting down the stragglers can take more than the 30 s
    # this used to allow. 2026-10-03 on chi2: two 930-candidate stages ended
    # 30 s past their deadline and the outer timer threw away every result
    # of both batches, 1,874 rows with no HTTP after 25 minutes of fetching.
    {http_us, http_res} = :timer.tc(fn -> await_stage(http_task, "http", http_stage_timeout(length(http_cands)) + 180_000) end)
    {bgp_us, bgp_res} = :timer.tc(fn -> await_stage(bgp_task, "bgp", 120_000) end)
    {rdap_us, rdap_res} = :timer.tc(fn -> await_stage(rdap_task, "rdap", rdap_timeout) end)

    # Candidates the stage deadline cut while in flight: no row (a row with
    # no HTTP outcome advanced http_last_checked_at and hid the site from
    # its refresh for a whole cadence, 150K rows a day on 2026-10-23), and
    # back to the tail of the queue instead.
    cut = unfetched(http_cands, http_res)
    fetched = http_cands -- cut
    http_err = length(cut)
    errors = if http_err > 0 do
      [%{time: now_iso(), msg: "HTTP: #{http_err}/#{length(http_cands)} not fetched by the deadline", stage: "http"} | errors]
    else
      errors
    end

    by_domain = Map.new(domains, fn d -> {d[:ctl_domain] || d[:domain], d} end)
    skipped =
      skipped
      |> Map.put(:returned_front, for({d, _ip} <- surplus, item = by_domain[d], do: item))
      |> Map.put(:returned_tail, for({d, _ip} <- cut, item = by_domain[d], do: item))
      |> Map.put(:child_rows, child_rows(http_res))

    # 4. Merge (reputation + classification + scoring happen here)
    {merge_us, merged} =
      :timer.tc(fn -> merge_results(rows_to_write(domains, dns_results, fetched), dns_results, http_res, bgp_res, rdap_res, worker) end)

    stages = %{
      dns: %{input: length(domains), output: map_size(dns_results), ms: div(dns_us, 1000)},
      http: %{input: length(http_cands), output: map_size(http_res), ms: div(http_us, 1000),
              filtered: length(domains) - length(http_cands) - length(surplus),
              surplus: length(surplus), cut: length(cut), cap: cap,
              cand_ratio: candidate_ratio(length(http_cands) + length(surplus), length(domains))},
      bgp: %{input: length(bgp_cands), output: map_size(bgp_res), ms: div(bgp_us, 1000)},
      rdap: %{input: length(rdap_cands), output: map_size(rdap_res), ms: div(rdap_us, 1000),
              rate_limited: length(rdap_cands) - map_size(rdap_res)},
      merge: %{input: length(domains), output: length(merged), ms: div(merge_us, 1000)},
      skipped: %{dormant: length(skipped.dormant), soft: length(skipped.soft), recent: length(skipped.recent), unresolved: length(unresolved),
                 no_ip: Enum.count(dns_results, fn {_d, r} -> List.wrap(get_in(r, [:dns, :a])) == [] end),
                 private_ip: Enum.count(dns_results, fn {_d, r} -> a = List.wrap(get_in(r, [:dns, :a])); a != [] and is_nil(LS.HTTP.SafeAddress.first_public(a)) end),
                 unresolved_refresh: length(skipped.unresolved_refresh)},
      total: length(merged)
    }

    samples = %{
      dns: dns_results |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.merge(flatten_dns(v), %{domain: d}) end),
      http: http_res |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      bgp: bgp_res |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      rdap: rdap_res |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      merged: Enum.take(merged, 5)
    }

    {merged, stages, samples, errors, skipped}
  end

  # ==========================================================================
  # DNS
  # ==========================================================================

  defp enrich_dns(domains, conc) do
    domains
    |> Task.async_stream(
      fn d ->
        # CTL items carry :ctl_domain; recrawl items carry :domain.
        domain = d[:ctl_domain] || d[:domain]
        case LS.DNS.Resolver.lookup(domain) do
          {:ok, dns} ->
            # DMARC / BIMI / DKIM ride along with the DNS stage, and only for
            # domains that have mail at all (2026-09-06, LS.DNS.EmailAuth).
            mx = List.wrap(dns[:mx])
            first_ip = LS.HTTP.SafeAddress.first_public(dns[:a])

            dns =
              dns
              |> Map.merge(LS.DNS.EmailAuth.lookup(domain, mx))
              |> Map.merge(LS.DNS.Infra.lookup(domain, first_ip, mx))

            {domain, %{dns: dns, scores: %{}}}
          {:error, _} ->
            {domain, %{
              dns: %{a: [], aaaa: [], mx: [], txt: [], cname: []},
            }}
        end
      end,
      max_concurrency: conc, timeout: 15_000,
      on_timeout: :kill_task, ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {d, r}}, acc -> Map.put(acc, d, r)
      {:exit, _}, acc -> acc
    end)
  end

  # ==========================================================================
  # CLASSIFY
  # ==========================================================================

  # Which resolved domains get an HTTP fetch, and what happens to the rest.
  #
  # Until 2026-10-01 every domain in the batch got a row, fetched or not:
  # 60% of all rows written (345M of the 506M in enrich_log, 189M of the
  # 305M in domains) were "resolved, filtered, never fetched", and 64% of
  # certificate re-sightings were those same domains coming back to be
  # filtered again. Now a filtered domain gets no row; the master is told
  # the verdict instead and remembers it in the crawl gate (dormant for a
  # verdict the name settles, 28-35 days for a missing mail setup).
  defp classify(dns_results, issuers, refresh) do
    Enum.reduce(dns_results, {[], [], %{dormant: [], soft: [], recent: []}}, fn {domain, data}, {ha, ba, sk} ->
      # Only a public address is a candidate (2026-10-26, LS.HTTP.SafeAddress):
      # a name that resolves to 10.0.0.x or 127.0.0.1 alone gets no fetch and
      # no row, like a name that does not resolve.
      ip = LS.HTTP.SafeAddress.first_public(data.dns[:a])
      ba = if ip && ip != "", do: [{domain, ip} | ba], else: ba
      mx = data.dns[:mx] |> List.wrap() |> Enum.join("|")
      txt = data.dns[:txt] |> List.wrap() |> Enum.join(" ")

      cond do
        is_nil(ip) or ip == "" ->
          {ha, ba, sk}

        # Blocklisted domains keep a row: the malware/phishing flag is data.
        Blocklist.blocked?(domain) ->
          {ha, ba, sk}

        Cache.http_lookup(domain) != :miss ->
          {ha, ba, %{sk | recent: [domain | sk.recent]}}

        LS.Reputation.TLDFilter.is_registry?(domain) ->
          {ha, ba, %{sk | dormant: [domain | sk.dormant]}}

        true ->
          case prefetch_verdict(domain, mx, txt, ip, Map.get(issuers, domain, ""), MapSet.member?(refresh, domain)) do
            :crawl -> {[{domain, ip} | ha], ba, sk}
            {:skip, :no_mail} -> {ha, ba, %{sk | soft: [domain | sk.soft]}}
            {:skip, _settled} -> {ha, ba, %{sk | dormant: [domain | sk.dormant]}}
          end
      end
    end)
  end

  @doc """
  Pure: whether a resolved domain gets a fetch. A refresh item (the
  scheduler's `source: :recrawl`) always does: its membership was decided
  by an observed 2xx, so the name filter that guards first contact (junk
  names, listed TLDs, no mail setup, low-yield issuers) has nothing to add.
  Until 2026-10-03 a known business without MX was soft-skipped on every
  refresh and never checked again. Blocklist, registry and the politeness
  cache are checked before this and are not bypassed.
  """
  @spec prefetch_verdict(String.t(), String.t(), String.t(), String.t() | nil, String.t(), boolean()) ::
          :crawl | {:skip, atom()}
  def prefetch_verdict(_domain, _mx, _txt, _ip, _issuer, true), do: :crawl
  def prefetch_verdict(domain, mx, txt, ip, issuer, false), do: DomainFilter.verdict(domain, mx, txt, ip, issuer)

  # What one HTTP candidate costs in budget slots. Measured 2026-10-23 on a
  # 160-domain probe and again 2026-10-24 in the batch logs: robots.txt
  # (cached 24 h, so always a miss at first contact and at any refresh 14
  # days or more apart), the homepage, and about a tenth of a login or
  # pricing page. The previous figure of 1.5 assumed robots.txt was free;
  # with it the deadline cut 100 to 235 of every 290 to 622 candidates and
  # those became hollow rows.
  # 2026-10-27, first two hours with the address page in the plan: a
  # candidate cost robots.txt, the homepage and one or two secondary pages
  # in sequence, the stage assumed 2.2 slots, and the deadline cut 124 of
  # 143 candidates per batch after their requests were already spent. The
  # fleet fell to 9 rows a minute per node at a full budget (12.7 requests
  # per row). Now the stage runs in two phases (see enrich_http/3): the
  # homepage first at @home_slots per candidate, then the secondary pages
  # for whatever finished until the stage deadline, dropped if not. The
  # cap counts both.
  @home_slots 2.2
  @secondary_slots 1.2
  @slots_per_candidate @home_slots + @secondary_slots
  # The share of the master's 10-minute in-flight timeout a batch may spend
  # fetching: DNS takes up to 30 s, merge and ML up to 60 s, 90 s margin.
  @http_window_ms 420_000

  @doc false
  # Pure: how long the HTTP stage may take for `n` candidates, each fetch
  # paced by the node budget, with a minute of slack for the slow tail.
  # The rate a batch can count on is the node ceiling divided by the
  # batches running at once (2026-10-03): with two batches sharing 120 a
  # minute, a 345-candidate stage sized for the whole ceiling ran into its
  # deadline at 319.5 s on ny1 and lost its tail.
  def http_stage_timeout(n, per_min \\ div(LS.HTTP.NodeBudget.lane_limit(:discovery), parallel_batches())),
    do: max(120_000, round(n * @slots_per_candidate * 60_000 / max(per_min, 1)) + 60_000)

  @doc """
  Pure: how many HTTP candidates one batch may carry so that its fetches,
  at `per_min` slots a minute and #{@slots_per_candidate} slots each, finish
  inside `window_ms`. Two batches sharing 120 a minute: 190 each.
  """
  @spec http_candidate_cap(pos_integer(), pos_integer()) :: pos_integer()
  def http_candidate_cap(per_min \\ div(LS.HTTP.NodeBudget.lane_limit(:discovery), parallel_batches()), window_ms \\ @http_window_ms),
    do: max(trunc(max(per_min, 1) * window_ms / 60_000 / @slots_per_candidate), 20)

  @doc "Pure: the candidates this batch fetches, and the surplus it hands back untouched."
  @spec split_candidates([term()], pos_integer()) :: {[term()], [term()]}
  def split_candidates(cands, cap) when is_list(cands) and is_integer(cap) and cap > 0, do: Enum.split(cands, cap)

  @doc "Pure: candidates the stage never returned a result for, success or error."
  @spec unfetched([{String.t(), term()}], map()) :: [{String.t(), term()}]
  def unfetched(cands, http_res) when is_list(cands) and is_map(http_res),
    do: Enum.reject(cands, fn {d, _ip} -> Map.has_key?(http_res, d) end)

  @doc """
  Pure: how many domains to dequeue so that, at the share of them that
  usually pass the gate (`ratio`), the batch lands near its candidate cap
  instead of resolving 1,000 names to fetch 190. Bounded to [100, max].
  """
  @spec dequeue_size(pos_integer(), number(), pos_integer()) :: pos_integer()
  def dequeue_size(cap, ratio, max) when is_integer(cap) and is_number(ratio) and is_integer(max) do
    r = ratio |> max(0.1) |> min(1.0)
    cap |> Kernel./(r) |> Float.ceil() |> trunc() |> max(100) |> min(max)
  end

  @doc false
  # Pure: the share of a batch that became HTTP candidates, clamped so one
  # odd batch cannot swing the next dequeue to an extreme.
  def candidate_ratio(_cands, 0), do: 0.4
  def candidate_ratio(cands, domains) when is_integer(cands) and is_integer(domains),
    do: (cands / domains) |> max(0.1) |> min(1.0)

  @doc """
  Pure: the http_contacts and http_people rows a batch's HTTP results carry
  (2026-10-26), stamped with the domain and the crawl time.
  """
  @spec child_rows(map()) :: %{contacts: [map()], people: [map()]}
  def child_rows(http_res) when is_map(http_res) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

    contacts =
      for {domain, r} <- http_res, is_map(r), c <- List.wrap(r[:_contacts]), is_map(c) do
        %{domain: domain, email: c.email, source_page: c.source_page, on_domain: c.on_domain, seen_at: now}
      end

    people =
      for {domain, r} <- http_res, is_map(r), p <- List.wrap(r[:_people]), is_map(p) do
        %{domain: domain, name: p.name, title: p.title || "", email: p.email || "", source_page: p.source || "homepage", seen_at: now}
      end

    %{contacts: contacts, people: people}
  end

  def child_rows(_), do: %{contacts: [], people: []}

  @doc """
  Pure: the domains of a batch that are refreshes of known businesses, by
  the scheduler (`source: :recrawl`) or by a certificate re-sighting the
  master tagged `known: true` (2026-10-26). These bypass the first-contact
  name gate: their membership was decided by an observed page, and gating
  them again parked thousands in the stable and dormant rings.
  """
  @spec refresh_set([map()]) :: MapSet.t()
  def refresh_set(domains) do
    for d <- domains, d[:source] == :recrawl or d[:known] == true, dom = d[:ctl_domain] || d[:domain], is_binary(dom), into: MapSet.new(), do: dom
  end

  @doc """
  Pure: the refresh items (`source: :recrawl`, or `known: true`) of a batch whose name did
  not resolve to an address on this worker and that are not HTTP
  candidates. Found 2026-10-26: the master's liveness check lets a SERVFAIL
  or a timeout through ("let a worker try"), the worker then dropped the
  name with no row and no count, its http_last_checked_at never moved, and
  the oldest-first due query returned it again 30 minutes later. About
  2,000 such names, last fetched in June, took 45% of every tier A tick
  for weeks. The master records a dns_unresolved check for these
  (LS.Recrawl.Liveness.record_dead/1, a full copy of the row, never a
  hollow one), so they wait their cadence like any checked business.
  """
  @spec unresolved_refresh([map()], map(), [{String.t(), term()}]) :: [String.t()]
  def unresolved_refresh(domains, dns_results, http_cands) do
    cands = MapSet.new(http_cands, fn {d, _ip} -> d end)

    for d <- domains,
        d[:source] == :recrawl or d[:known] == true,
        dom = d[:ctl_domain] || d[:domain],
        is_binary(dom) and dom != "",
        not MapSet.member?(cands, dom),
        is_nil(LS.HTTP.SafeAddress.first_public(get_in(dns_results, [dom, :dns, :a]))),
        do: dom
  end

  @doc false
  # Pure: the domains that get a row. Fetched ones (HTTP has something to
  # say, including the error), blocklisted ones (the flag is the data).
  # Filtered and unresolved domains write nothing: a row with DNS fields
  # only used to REPLACE a good `domains` row with a hollow one. Since
  # 2026-10-24 the caller passes only candidates the stage returned a
  # result for; a candidate the deadline cut goes back to the queue.
  def rows_to_write(domains, dns_results, http_cands) do
    attempted = MapSet.new(http_cands, fn {d, _ip} -> d end)

    Enum.filter(domains, fn d ->
      domain = d[:ctl_domain] || d[:domain]
      MapSet.member?(attempted, domain) or (Map.has_key?(dns_results, domain) and Blocklist.blocked?(domain))
    end)
  end

  defp classify_rdap(dns_results) do
    # Same quality gate as the HTTP stage (2026-07-27): registry lookups are
    # politeness-limited to 2/s, which made RDAP the slowest stage of every
    # batch (~108s of a ~250s cycle) while ~93% of its candidates were domains
    # that will never pass the crawl gate. Now only crawl-worthy domains
    # (resolvable + high-value TLD + MX + SPF via DomainFilter.should_crawl?)
    # spend registry budget — RDAP wall time tracks the HTTP stage it runs in
    # parallel with, instead of dominating it.
    Enum.reduce(dns_results, [], fn {domain, data}, acc ->
      ip = LS.HTTP.SafeAddress.first_public(data.dns[:a])
      mx = data.dns[:mx] |> List.wrap() |> Enum.join("|")
      txt = data.dns[:txt] |> List.wrap() |> Enum.join(" ")
      if ip && ip != "" && Cache.rdap_lookup(domain) == :miss && !Blocklist.blocked?(domain) &&
           !LS.Reputation.TLDFilter.is_registry?(domain) && DomainFilter.should_crawl?(domain, mx, txt) do
        [domain | acc]
      else
        acc
      end
    end)
  end

  # ==========================================================================
  # HTTP
  # ==========================================================================

  defp enrich_http([], _, _), do: %{}

  defp enrich_http(cands, conc, prev_simhash) do
    n = length(cands)
    per_min = div(LS.HTTP.NodeBudget.lane_limit(:discovery), parallel_batches())
    bound = http_stage_timeout(n)
    start = System.monotonic_time(:millisecond)
    deadline = start + bound
    # Phase 1 gets the homepage share of the bound plus the slack; phase 2
    # whatever is left until the stage deadline.
    home_deadline = start + max(120_000, round(n * @home_slots * 60_000 / max(per_min, 1)) + 60_000)

    stream =
      Task.async_stream(
        cands,
        fn {d, ip} ->
          r = do_http(d, ip, Map.get(prev_simhash, d))
          Cache.http_insert(d)
          {d, {r, ip}}
        end,
        # Each task may sleep until its reserved budget slot (LS.HTTP.NodeBudget),
        # so the per-task bound is the stage bound, not the homepage budget.
        max_concurrency: conc, timeout: bound, on_timeout: :kill_task, ordered: false
      )

    {res, cut} = collect_until(stream, min(home_deadline, deadline), n)
    if cut > 0, do: Logger.warning("http stage deadline: #{cut} of #{n} candidates not fetched, #{map_size(res)} kept")

    homes = Map.new(res, fn {d, {r, _ip}} -> {d, r} end)
    secondary_pages(homes, res, conc, deadline)
  end

  # Phase 2: the secondary pages (LS.Pipeline.secondary_plan/2) for the
  # homepages that finished, as many as the stage deadline allows. A page
  # that does not make it is dropped: the homepage row is already in hand
  # and is never lost to a slow contact page. Fault-isolated per domain.
  defp secondary_pages(homes, res, conc, deadline) do
    due =
      for {d, {r, ip}} <- res,
          is_map(r),
          r[:http_status] == 200,
          r[:_secondary_due] != false,
          LS.Pipeline.secondary_plan(r[:http_tech], r[:http_pages]) != [],
          do: {d, r, ip}

    remaining = deadline - System.monotonic_time(:millisecond)

    if due == [] or remaining < 15_000 do
      homes
    else
      stream =
        Task.async_stream(due, fn {d, r, ip} -> {d, LS.Pipeline.secondary(r, d, ip)} end,
          max_concurrency: conc, timeout: remaining, on_timeout: :kill_task, ordered: false)

      {enhanced, dropped} = collect_until(stream, deadline, length(due))
      if dropped > 0, do: Logger.info("secondary pages: #{dropped} of #{length(due)} not read by the deadline")
      Map.merge(homes, enhanced)
    end
  rescue
    _ -> homes
  end

  @doc false
  # Consume a result stream until the deadline, KEEPING what finished.
  # Until 2026-10-02 the HTTP stage ran in a task that the batch killed on
  # overrun, and every fetched page of the batch went with it: with the node
  # budget pacing fetches, 3 to 4 stages an hour per worker overran and 41%
  # of rows were hollow. Halting the stream shuts the pending tasks down;
  # the ones that finished are returned. Returns {results, not_finished}.
  def collect_until(stream, deadline_ms, total) do
    {res, n} =
      Enum.reduce_while(stream, {%{}, 0}, fn item, {acc, n} ->
        acc =
          case item do
            {:ok, {d, r}} -> Map.put(acc, d, r)
            _ -> acc
          end

        if System.monotonic_time(:millisecond) >= deadline_ms, do: {:halt, {acc, n + 1}}, else: {:cont, {acc, n + 1}}
      end)

    {res, max(total - n, 0)}
  end

  defp do_http(domain, ip, prev_simhash), do: LS.Pipeline.http(domain, ip, prev_simhash: prev_simhash, secondary: false)

  # ==========================================================================
  # RDAP
  # ==========================================================================

  defp enrich_rdap([], _), do: %{}
  defp enrich_rdap(cands, conc) do
    cands
    |> Task.async_stream(
      fn d ->
        case RDAPClient.lookup(d) do
          {:ok, data} ->
            Cache.rdap_insert(d)
            {d, data}
          {:error, :rate_limited} ->
            Process.sleep(600)
            case RDAPClient.lookup(d) do
              {:ok, data} -> Cache.rdap_insert(d); {d, data}
              _ -> {d, :skip}
            end
          {:error, _} ->
            # Do NOT cache a failure: writing to the 90-day done-cache here
            # meant a registry timeout froze the gap permanently, since every
            # recrawl saw a hit and never retried. That is a large part of why
            # only 63.5% of .com businesses carried a creation date (measured
            # 2026-08-27). A miss simply retries on the next recrawl.
            {d, :skip}
        end
      end,
      max_concurrency: conc, timeout: 15_000,
      on_timeout: :kill_task, ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {_, :skip}}, acc -> acc
      {:ok, {d, r}}, acc -> Map.put(acc, d, r)
      {:exit, _}, acc -> acc
    end)
  end

  # ==========================================================================
  # BGP
  # ==========================================================================

  defp enrich_bgp([]), do: %{}
  defp enrich_bgp(cands) do
    ips = Enum.map(cands, fn {_, ip} -> ip end) |> Enum.uniq()
    # Cymru lookups run 100 IPs/query with a polite 2s inter-query delay through
    # one serialized GenServer, so wall time scales with unique-IP count: ~900
    # cold IPs need 60-130s. The old fixed 60s timeout made the linked batch
    # task exit mid-flight and took the whole WorkerAgent down with it (h1
    # crash-loop, 2026-07-27) — and any worker could hit it on a cold cache.
    bgp_timeout = max(60_000, div(length(ips), 100) * 10_000 + 30_000)
    asn_map = bgp_lookup(BGPResolver, ips, bgp_timeout)
    Enum.reduce(cands, %{}, fn {d, ip}, acc ->
      case Map.get(asn_map, ip) do
        nil -> acc
        a ->
          Map.put(acc, d, %{
            bgp_ip: ip,
            bgp_asn_number: a.asn || "",
            bgp_asn_org: a.org || "",
            bgp_asn_country: a.country || "",
            bgp_asn_prefix: a.prefix || "",
          })
      end
    end)
  rescue
    _ -> %{}
  end

  @doc false
  # A resolver that does not answer in time costs the batch its BGP fields,
  # never the batch. GenServer.call raises an exit on timeout, which the
  # `rescue` below never saw: on 2026-10-01 whois.cymru.com port 43 was
  # unreachable from both Paris nodes and par1/par2 crash-looped for two
  # hours (84 and 74 agent restarts, zero batches completed), the same
  # shape as h1 on 2026-07-27.
  def bgp_lookup(server, ips, timeout_ms) do
    case GenServer.call(server, {:lookup_batch, ips}, timeout_ms) do
      {:ok, m} when is_map(m) -> m
      _ -> %{}
    end
  catch
    :exit, reason ->
      require Logger
      Logger.warning("BGP stage skipped for #{length(ips)} IPs: #{inspect(reason) |> String.slice(0, 120)}")
      %{}
  end

  # ==========================================================================
  # MERGE
  # ==========================================================================

  defp merge_results(domains, dns_res, http_res, bgp_res, rdap_res, worker) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)
    Enum.map(domains, fn d ->
      domain = d[:ctl_domain] || d[:domain]
      ctl = %{ctl_tld: d[:ctl_tld], ctl_issuer: d[:ctl_issuer],
              ctl_subdomain_count: d[:ctl_subdomain_count], ctl_subdomains: d[:ctl_subdomains]}
      dns = Map.get(dns_res, domain, %{dns: %{}, scores: %{}})
      http = Map.get(http_res, domain, %{})
      bgp = Map.get(bgp_res, domain, %{})
      rdap = Map.get(rdap_res, domain, %{})
      LS.Pipeline.merge_row(domain, dns, http, bgp, rdap, worker, now, ctl, ml: :defer)
    end)
    |> finalize_ml()
  end

  # One batched inference for the whole batch's ML-fallback texts (the serving
  # is compiled batch_size 8 — single calls were padding 7 of 8 slots).
  defp finalize_ml(rows) do
    {t_us, finalized} = :timer.tc(fn ->
      indexed = Enum.with_index(rows)
      needs = for {row, i} <- indexed, is_binary(row[:_ml_text]), do: {i, row[:_ml_text]}

      case needs do
        [] ->
          Enum.map(rows, &LS.Pipeline.strip_ml_defer/1)

        _ ->
          results = LS.ML.Classifier.classify_batch(Enum.map(needs, &elem(&1, 1)))
          ml_by_index = Enum.zip(Enum.map(needs, &elem(&1, 0)), results) |> Map.new()

          Enum.map(indexed, fn {row, i} ->
            case ml_by_index do
              %{^i => ml} -> LS.Pipeline.apply_ml(row, ml)
              _ -> LS.Pipeline.strip_ml_defer(row)
            end
          end)
      end
    end)

    :persistent_term.put({__MODULE__, :last_ml_ms}, div(t_us, 1000))
    finalized
  end

  # ==========================================================================
  # HELPERS
  # ==========================================================================

  defp flatten_dns(%{dns: d, scores: _s}) do
    %{
      a: d[:a] |> List.wrap() |> Enum.join(", "),
      mx: d[:mx] |> List.wrap() |> Enum.join(", "),
    }
  end
  defp flatten_dns(_), do: %{}

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

end
