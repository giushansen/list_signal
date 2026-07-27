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

  @http_timeout 25_000
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
    {:reply, %{draining: s.draining, idle: s.current_batch == nil}, s}
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

  @impl true
  def handle_info(:pull_work, s) do
    queue = {LS.Cluster.WorkQueue, s.master_node}
    parent = self()
    %{http_concurrency: hc, dns_concurrency: dc, rdap_concurrency: rc, batch_size: bs} = s
    spawn_link(fn ->
      try do
        case GenServer.call(queue, {:dequeue, bs}, 15_000) do
          {:ok, bid, domains} ->
            Logger.info("Batch #{bid}: #{length(domains)} domains")
            t0 = System.monotonic_time(:millisecond)
            {results, stages, samples, errors} = enrich_batch(domains, hc, dc, rc)
            stages = Map.put(stages, :cycle_ms, System.monotonic_time(:millisecond) - t0)
            send(parent, {:batch_done, bid, results, stages, samples, errors})
          {:empty, []} ->
            send(parent, :batch_empty)
        end
      catch
        :exit, reason -> send(parent, {:batch_error, reason})
      end
    end)
    {:noreply, %{s | current_batch: :working}}
  end

  @impl true
  def handle_info({:batch_done, bid, results, stages, samples, batch_errors}, s) do
    queue = {LS.Cluster.WorkQueue, s.master_node}
    cyc = Map.get(stages, :cycle_ms, 0)
    known = stages.dns.ms + max(stages.http.ms, max(stages.bgp.ms, stages.rdap.ms)) + get_in(stages, [:merge, :ms])
    Logger.info("Batch #{bid}: #{length(results)} rows (DNS:#{stages.dns.ms}ms HTTP:#{stages.http.ms}ms BGP:#{stages.bgp.ms}ms RDAP:#{stages.rdap.ms}ms MERGE:#{get_in(stages, [:merge, :ms])}ms (ML:#{:persistent_term.get({__MODULE__, :last_ml_ms}, 0)}ms) | cycle #{cyc}ms, unaccounted #{max(cyc - known, 0)}ms)")
    GenServer.cast(queue, {:complete, bid, results})
    errors = (batch_errors ++ s.errors) |> Enum.take(@max_errors)
    new_s = %{s |
      total_enriched: s.total_enriched + length(results),
      total_batches: s.total_batches + 1,
      current_batch: nil,
      last_stages: stages,
      last_samples: samples,
      errors: errors
    }
    unless new_s.draining, do: send(self(), :pull_work)
    {:noreply, new_s}
  end

  @impl true
  def handle_info(:batch_empty, s) do
    unless s.draining, do: Process.send_after(self(), :pull_work, @empty_queue_wait_ms)
    {:noreply, %{s | current_batch: nil}}
  end

  @impl true
  def handle_info({:batch_error, reason}, s) do
    err = %{time: now_iso(), msg: "Lost master: #{inspect(reason)}", stage: "connection"}
    errors = [err | s.errors] |> Enum.take(@max_errors)
    Process.send_after(self(), :connect_and_work, @reconnect_interval_ms)
    {:noreply, %{s | connected: false, current_batch: nil, errors: errors}}
  end

  @impl true
  def handle_info(_msg, s), do: {:noreply, s}

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
    {http_cands, bgp_cands} = classify(dns_results)
    rdap_cands = classify_rdap(dns_results)

    # 3. Parallel: HTTP + BGP + RDAP
    http_task = Task.async(fn -> enrich_http(http_cands, http_c) end)
    bgp_task = Task.async(fn -> enrich_bgp(bgp_cands) end)
    rdap_task = Task.async(fn -> enrich_rdap(rdap_cands, rdap_c) end)

    # RDAP is rate-limited (politeness), so its wall time scales with candidate
    # count — a fixed await here crash-looped h1 when batch_size=2000 pushed
    # RDAP past 120s (2026-07-27). Timeouts now scale, and an overrunning stage
    # is shut down and skipped instead of killing the whole batch (its domains
    # still get rows, just without that stage's fields).
    rdap_timeout = max(120_000, length(rdap_cands) * 1_000)
    {http_us, http_res} = :timer.tc(fn -> await_stage(http_task, "http", 120_000) end)
    {bgp_us, bgp_res} = :timer.tc(fn -> await_stage(bgp_task, "bgp", 120_000) end)
    {rdap_us, rdap_res} = :timer.tc(fn -> await_stage(rdap_task, "rdap", rdap_timeout) end)

    http_err = length(http_cands) - map_size(http_res)
    errors = if http_err > 0 do
      [%{time: now_iso(), msg: "HTTP: #{http_err}/#{length(http_cands)} failed", stage: "http"} | errors]
    else
      errors
    end

    # 4. Merge (reputation + classification + scoring happen here)
    {merge_us, merged} = :timer.tc(fn -> merge_results(domains, dns_results, http_res, bgp_res, rdap_res, worker) end)

    stages = %{
      dns: %{input: length(domains), output: map_size(dns_results), ms: div(dns_us, 1000)},
      http: %{input: length(http_cands), output: map_size(http_res), ms: div(http_us, 1000),
              filtered: length(domains) - length(http_cands)},
      bgp: %{input: length(bgp_cands), output: map_size(bgp_res), ms: div(bgp_us, 1000)},
      rdap: %{input: length(rdap_cands), output: map_size(rdap_res), ms: div(rdap_us, 1000),
              rate_limited: length(rdap_cands) - map_size(rdap_res)},
      merge: %{input: length(domains), output: length(merged), ms: div(merge_us, 1000)},
      total: length(merged)
    }

    samples = %{
      dns: dns_results |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.merge(flatten_dns(v), %{domain: d}) end),
      http: http_res |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      bgp: bgp_res |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      rdap: rdap_res |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      merged: Enum.take(merged, 5)
    }

    {merged, stages, samples, errors}
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
            scores = %{}
            {domain, %{dns: dns, scores: scores}}
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

  defp classify(dns_results) do
    Enum.reduce(dns_results, {[], []}, fn {domain, data}, {ha, ba} ->
      ip = data.dns[:a] |> List.wrap() |> List.first()
      ba = if ip && ip != "", do: [{domain, ip} | ba], else: ba
      mx = data.dns[:mx] |> List.wrap() |> Enum.join("|")
      txt = data.dns[:txt] |> List.wrap() |> Enum.join(" ")
      # Skip HTTP for blocklisted domains
      ha = if ip && ip != "" && Cache.http_lookup(domain) == :miss &&
              !Blocklist.blocked?(domain) && !LS.Reputation.TLDFilter.is_registry?(domain) && DomainFilter.should_crawl?(domain, mx, txt) do
        [{domain, ip} | ha]
      else
        ha
      end
      {ha, ba}
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
      ip = data.dns[:a] |> List.wrap() |> List.first()
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

  defp enrich_http([], _), do: %{}
  defp enrich_http(cands, conc) do
    cands
    |> Task.async_stream(
      fn {d, ip} ->
        r = do_http(d, ip)
        Cache.http_insert(d)
        {d, r}
      end,
      # Homepage budget + up to 2 best-effort secondary fetches (login/pricing),
      # each ≤10s plus per-IP rate-limiter spacing. Raised so a secondary fetch can
      # never time out the task and drop the (sacred) homepage row.
      max_concurrency: conc, timeout: @http_timeout + 35_000,
      on_timeout: :kill_task, ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {d, r}}, acc -> Map.put(acc, d, r)
      {:exit, _}, acc -> acc
    end)
  end

  defp do_http(domain, ip), do: LS.Pipeline.http(domain, ip)

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
            Cache.rdap_insert(d)
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
    asn_map = case GenServer.call(BGPResolver, {:lookup_batch, ips}, bgp_timeout) do
      {:ok, m} -> m
      {:error, _} -> %{}
    end
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
