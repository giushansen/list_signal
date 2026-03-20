defmodule LS.Cluster.WorkerAgent do
  @moduledoc """
  Worker agent — runs on each worker node.

  Connects to master, pulls domain batches, runs DNS → HTTP + BGP enrichment,
  returns completed rows to master for ClickHouse insertion.

  No files. Everything in memory.

  ## Key design: non-blocking GenServer

  Enrichment runs in a spawned process, NOT inside handle_info.
  This keeps the GenServer responsive for :stats, :detailed_stats, and :peek
  calls from the dashboard (which would otherwise timeout during the 30-50s
  enrichment cycle).

  ## Flow per batch

      1. Pull 1000 domains from master WorkQueue
      2. DNS (all domains, 500 concurrent, ~5ms each)
      3. HTTP (filtered domains only, 100 concurrent, ~5-25s each — the bottleneck)
      4. BGP (domains with A records, batched via Team Cymru)
      5. Merge into complete rows
      6. Return to master
      7. Loop
  """

  use GenServer
  require Logger

  alias LS.DNS.{Resolver, Scorer}
  alias LS.HTTP.{Client, DomainFilter, TechDetector, PageExtractor}
  alias LS.BGP.Resolver, as: BGPResolver
  alias LS.BGP.Scorer, as: BGPScorer
  alias LS.Cache

  @http_timeout 25_000
  @reconnect_interval_ms 10_000
  @empty_queue_wait_ms 30_000
  @max_errors 50

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    master_node = System.get_env("LS_MASTER", "master@10.0.0.1") |> String.to_atom()
    http_concurrency = System.get_env("LS_HTTP_CONCURRENCY", "100") |> String.to_integer()
    dns_concurrency = System.get_env("LS_DNS_CONCURRENCY", "500") |> String.to_integer()
    batch_size = System.get_env("LS_BATCH_SIZE", "1000") |> String.to_integer()

    LS.HTTP.DomainFilter.load_tlds()

    state = %{
      master_node: master_node,
      connected: false,
      http_concurrency: http_concurrency,
      dns_concurrency: dns_concurrency,
      batch_size: batch_size,
      total_enriched: 0,
      total_batches: 0,
      current_batch: nil,
      start_time: System.monotonic_time(:second),
      # Stage stats from last completed batch (for dashboard)
      last_stages: nil,
      # Sample rows per stage for peek (5 each, ~5KB total)
      last_samples: %{},
      # Error ring buffer (last N errors for dashboard)
      errors: []
    }

    send(self(), :connect_and_work)
    Logger.info("🔧 WorkerAgent starting (master: #{master_node}, batch: #{batch_size}, HTTP: #{http_concurrency}, DNS: #{dns_concurrency})")
    {:ok, state}
  end

  # ==========================================================================
  # STATS — always responsive (never blocked by enrichment)
  # ==========================================================================

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, basic_stats(state), state}
  end

  @impl true
  def handle_call(:detailed_stats, _from, state) do
    stats = basic_stats(state) |> Map.put(:last_stages, state.last_stages)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:peek, stage}, _from, state) do
    samples = Map.get(state.last_samples, stage, [])
    {:reply, samples, state}
  end

  @impl true
  def handle_call(:errors, _from, state) do
    {:reply, state.errors, state}
  end

  defp basic_stats(state) do
    uptime = System.monotonic_time(:second) - state.start_time
    %{
      master_node: state.master_node,
      connected: state.connected,
      http_concurrency: state.http_concurrency,
      dns_concurrency: state.dns_concurrency,
      batch_size: state.batch_size,
      total_enriched: state.total_enriched,
      total_batches: state.total_batches,
      current_batch: state.current_batch,
      domains_per_sec: if(uptime > 0, do: Float.round(state.total_enriched / uptime, 2), else: 0.0),
      uptime_seconds: uptime,
      error_count: length(state.errors)
    }
  end

  # ==========================================================================
  # CONNECTION
  # ==========================================================================

  @impl true
  def handle_info(:connect_and_work, state) do
    case Node.connect(state.master_node) do
      true ->
        send(self(), :pull_work)
        {:noreply, %{state | connected: true}}
      _ ->
        Logger.warning("⏳ Cannot reach master #{state.master_node}, retrying in #{div(@reconnect_interval_ms, 1000)}s...")
        Process.send_after(self(), :connect_and_work, @reconnect_interval_ms)
        {:noreply, %{state | connected: false}}
    end
  end

  # ==========================================================================
  # WORK LOOP — enrichment runs in a spawned process
  # ==========================================================================

  @impl true
  def handle_info(:pull_work, state) do
    queue = {LS.Cluster.WorkQueue, state.master_node}
    parent = self()
    http_concurrency = state.http_concurrency
    dns_concurrency = state.dns_concurrency
    batch_size = state.batch_size

    # Spawn enrichment so GenServer stays responsive for stats/peek
    spawn_link(fn ->
      try do
        case GenServer.call(queue, {:dequeue, batch_size}, 15_000) do
          {:ok, batch_id, domains} ->
            Logger.info("📦 Batch #{batch_id}: #{length(domains)} domains")
            {results, stages, samples, errors} = enrich_batch(domains, http_concurrency, dns_concurrency)
            send(parent, {:batch_done, batch_id, results, stages, samples, errors})

          {:empty, []} ->
            send(parent, :batch_empty)
        end
      catch
        :exit, reason ->
          send(parent, {:batch_error, reason})
      end
    end)

    {:noreply, %{state | current_batch: :working}}
  end

  @impl true
  def handle_info({:batch_done, batch_id, results, stages, samples, batch_errors}, state) do
    queue = {LS.Cluster.WorkQueue, state.master_node}

    Logger.info(
      "✅ Batch #{batch_id}: #{length(results)} enriched " <>
      "(DNS:#{stages.dns.ms}ms HTTP:#{stages.http.ms}ms BGP:#{stages.bgp.ms}ms)"
    )

    GenServer.cast(queue, {:complete, batch_id, results})

    # Merge batch errors into ring buffer
    errors = (batch_errors ++ state.errors) |> Enum.take(@max_errors)

    {:noreply, %{state |
      total_enriched: state.total_enriched + length(results),
      total_batches: state.total_batches + 1,
      current_batch: nil,
      last_stages: stages,
      last_samples: samples,
      errors: errors
    } |> then(fn s -> send(self(), :pull_work); s end)}
  end

  @impl true
  def handle_info(:batch_empty, state) do
    Logger.debug("📭 Queue empty, waiting #{div(@empty_queue_wait_ms, 1000)}s...")
    Process.send_after(self(), :pull_work, @empty_queue_wait_ms)
    {:noreply, %{state | current_batch: nil}}
  end

  @impl true
  def handle_info({:batch_error, reason}, state) do
    error = %{time: DateTime.utc_now() |> DateTime.to_iso8601(), msg: "Lost master: #{inspect(reason)}", stage: "connection"}
    errors = [error | state.errors] |> Enum.take(@max_errors)

    Logger.warning("⚠️  Lost connection to master: #{inspect(reason)}")
    Process.send_after(self(), :connect_and_work, @reconnect_interval_ms)
    {:noreply, %{state | connected: false, current_batch: nil, errors: errors}}
  end

  # Ignore unexpected messages from spawned processes
  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ==========================================================================
  # ENRICHMENT — all in-memory, no files
  # ==========================================================================

  defp enrich_batch(domains, http_concurrency, dns_concurrency) do
    worker_name = Node.self() |> Atom.to_string()
    errors = []

    # 1. DNS (all domains)
    {dns_us, dns_results} = :timer.tc(fn -> enrich_dns(domains, dns_concurrency) end)
    dns_timeouts = length(domains) - map_size(dns_results)
    errors = if dns_timeouts > 0,
      do: [%{time: now_iso(), msg: "DNS: #{dns_timeouts}/#{length(domains)} timed out", stage: "dns"} | errors],
      else: errors

    # 2. Classify: which get HTTP, which get BGP
    {http_candidates, bgp_candidates} = classify(dns_results)

    # 3. HTTP (filtered, slow)
    {http_us, http_results} = :timer.tc(fn -> enrich_http(http_candidates, http_concurrency) end)
    http_errors_count = length(http_candidates) - map_size(http_results)
    errors = if http_errors_count > 0,
      do: [%{time: now_iso(), msg: "HTTP: #{http_errors_count}/#{length(http_candidates)} failed", stage: "http"} | errors],
      else: errors

    # 4. BGP (batched)
    {bgp_us, bgp_results} = :timer.tc(fn -> enrich_bgp(bgp_candidates) end)
    bgp_missing = length(bgp_candidates) - map_size(bgp_results)
    errors = if bgp_missing > length(bgp_candidates) * 0.5 and length(bgp_candidates) > 0,
      do: [%{time: now_iso(), msg: "BGP: #{bgp_missing}/#{length(bgp_candidates)} missing", stage: "bgp"} | errors],
      else: errors

    # 5. Merge
    merged = merge_results(domains, dns_results, http_results, bgp_results, worker_name)

    # 6. Stage stats
    stages = %{
      dns: %{input: length(domains), output: map_size(dns_results), ms: div(dns_us, 1000)},
      http: %{
        input: length(http_candidates),
        output: map_size(http_results),
        ms: div(http_us, 1000),
        filtered: length(domains) - length(http_candidates)
      },
      bgp: %{input: length(bgp_candidates), output: map_size(bgp_results), ms: div(bgp_us, 1000)},
      total: length(merged)
    }

    # 7. Samples for peek (5 from each stage — negligible cost)
    samples = %{
      dns: dns_results |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.merge(flatten_dns(v), %{domain: d}) end),
      http: http_results |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      bgp: bgp_results |> Enum.take(5) |> Enum.map(fn {d, v} -> Map.put(v, :domain, d) end),
      merged: Enum.take(merged, 5)
    }

    {merged, stages, samples, errors}
  end

  defp flatten_dns(%{dns: dns, scores: scores}) do
    %{
      a: dns[:a] |> List.wrap() |> Enum.join(", "),
      mx: dns[:mx] |> List.wrap() |> Enum.join(", "),
      txt: dns[:txt] |> List.wrap() |> Enum.join(", ") |> String.slice(0, 100),
      dns_web_scoring: scores[:dns_web_scoring] || 0,
      dns_email_scoring: scores[:dns_email_scoring] || 0
    }
  end
  defp flatten_dns(_), do: %{}

  defp now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ==========================================================================
  # DNS
  # ==========================================================================

  defp enrich_dns(domains, dns_concurrency) do
    domains
    |> Task.async_stream(
      fn domain_data ->
        domain = domain_data.ctl_domain
        case Resolver.lookup(domain) do
          {:ok, dns_data} ->
            scores = Scorer.score(%{domain: domain, dns: dns_data})
            {domain, %{dns: dns_data, scores: scores}}
          {:error, _} ->
            {domain, %{dns: %{a: [], aaaa: [], mx: [], txt: [], cname: []},
                        scores: %{dns_web_scoring: 0, dns_email_scoring: 0,
                                   dns_budget_scoring: 0, dns_security_scoring: 0}}}
        end
      end,
      max_concurrency: dns_concurrency, timeout: 15_000,
      on_timeout: :kill_task, ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {domain, result}}, acc -> Map.put(acc, domain, result)
      {:exit, _}, acc -> acc
    end)
  end

  # ==========================================================================
  # CLASSIFY
  # ==========================================================================

  defp classify(dns_results) do
    Enum.reduce(dns_results, {[], []}, fn {domain, data}, {http_acc, bgp_acc} ->
      dns = data.dns
      first_ip = dns[:a] |> List.wrap() |> List.first()

      bgp_acc = if first_ip && first_ip != "",
        do: [{domain, first_ip} | bgp_acc], else: bgp_acc

      mx_str = dns[:mx] |> List.wrap() |> Enum.join("|")
      txt_str = dns[:txt] |> List.wrap() |> Enum.join(" ")

      http_acc = if first_ip && first_ip != "" &&
                    Cache.http_lookup(domain) == :miss &&
                    DomainFilter.should_crawl?(domain, mx_str, txt_str),
        do: [{domain, first_ip} | http_acc], else: http_acc

      {http_acc, bgp_acc}
    end)
  end

  # ==========================================================================
  # HTTP
  # ==========================================================================

  defp enrich_http([], _), do: %{}
  defp enrich_http(candidates, concurrency) do
    candidates
    |> Task.async_stream(
      fn {domain, ip} ->
        result = do_http(domain, ip)
        Cache.http_insert(domain)
        {domain, result}
      end,
      max_concurrency: concurrency, timeout: @http_timeout + 5_000,
      on_timeout: :kill_task, ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {domain, result}}, acc -> Map.put(acc, domain, result)
      {:exit, _}, acc -> acc
    end)
  end

  defp do_http(domain, ip) do
    case Client.fetch(domain, ip) do
      {:ok, response} ->
        tech = TechDetector.detect(response)
        body = response.body || ""
        {pages, emails} = PageExtractor.extract_all(body, domain)
        %{
          http_status: response.status,
          http_response_time: response[:elapsed_ms],
          http_server: get_header(response, "server"),
          http_cdn: tech[:cdn] || "",
          http_blocked: tech[:blocked] || "",
          http_content_type: get_header(response, "content-type"),
          http_tech: tech[:tech] |> List.wrap() |> Enum.join("|"),
          http_tools: tech[:tools] |> List.wrap() |> Enum.join("|"),
          http_is_js_site: to_string(tech[:is_js_site] || false),
          http_title: extract_title(body),
          http_meta_description: extract_meta_description(body),
          http_pages: pages || "",
          http_emails: emails || "",
          http_error: ""
        }
      {:error, reason, _} -> %{http_error: to_string(reason)}
      {:error, reason} -> %{http_error: to_string(reason)}
    end
  rescue
    e -> %{http_error: "crash:#{Exception.message(e)}"}
  end

  defp extract_title(body) when is_binary(body) do
    case Regex.run(~r/<title[^>]*>([^<]{1,500})<\/title>/is, body) do
      [_, title] -> title |> String.trim() |> String.slice(0, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end
  defp extract_title(_), do: ""

  defp extract_meta_description(body) when is_binary(body) do
    case Regex.run(~r/<meta[^>]*name\s*=\s*["']description["'][^>]*content\s*=\s*["']([^"']{1,1000})["']/is, body) do
      [_, desc] -> desc |> String.trim() |> String.slice(0, 500)
      _ ->
        # Try reverse order (content before name)
        case Regex.run(~r/<meta[^>]*content\s*=\s*["']([^"']{1,1000})["'][^>]*name\s*=\s*["']description["']/is, body) do
          [_, desc] -> desc |> String.trim() |> String.slice(0, 500)
          _ -> ""
        end
    end
  rescue
    _ -> ""
  end
  defp extract_meta_description(_), do: ""

  defp get_header(%{headers: h}, name) when is_map(h), do: Map.get(h, name, "")
  defp get_header(%{headers: h}, name) when is_list(h) do
    case List.keyfind(h, name, 0) do
      {_, v} -> v
      nil -> ""
    end
  end
  defp get_header(_, _), do: ""

  # ==========================================================================
  # BGP
  # ==========================================================================

  defp enrich_bgp([]), do: %{}
  defp enrich_bgp(candidates) do
    ips = Enum.map(candidates, fn {_, ip} -> ip end) |> Enum.uniq()
    asn_map = case GenServer.call(BGPResolver, {:lookup_batch, ips}, 60_000) do
      {:ok, map} -> map
      {:error, _} -> %{}
    end

    Enum.reduce(candidates, %{}, fn {domain, ip}, acc ->
      case Map.get(asn_map, ip) do
        nil -> acc
        asn_data ->
          scores = BGPScorer.score(asn_data)
          Map.put(acc, domain, %{
            bgp_ip: ip,
            bgp_asn_number: asn_data.asn || "",
            bgp_asn_org: asn_data.org || "",
            bgp_asn_country: asn_data.country || "",
            bgp_asn_prefix: asn_data.prefix || "",
            bgp_web_scoring: scores.bgp_web_scoring,
            bgp_budget_scoring: scores.bgp_budget_scoring
          })
      end
    end)
  rescue
    _ -> %{}
  end

  # ==========================================================================
  # MERGE
  # ==========================================================================

  defp merge_results(domains, dns_results, http_results, bgp_results, worker_name) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

    Enum.map(domains, fn d ->
      domain = d.ctl_domain
      dns = Map.get(dns_results, domain, %{dns: %{}, scores: %{}})
      http = Map.get(http_results, domain, %{})
      bgp = Map.get(bgp_results, domain, %{})

      %{
        enriched_at: now,
        worker: worker_name,
        domain: domain,
        ctl_tld: d[:ctl_tld] || "",
        ctl_issuer: d[:ctl_issuer] || "",
        ctl_subdomain_count: d[:ctl_subdomain_count],
        ctl_subdomains: d[:ctl_subdomains] || "",
        ctl_web_scoring: d[:ctl_web_scoring],
        ctl_budget_scoring: d[:ctl_budget_scoring],
        ctl_security_scoring: d[:ctl_security_scoring],
        dns_a: dns.dns[:a] |> List.wrap() |> Enum.join("|"),
        dns_aaaa: dns.dns[:aaaa] |> List.wrap() |> Enum.join("|"),
        dns_mx: dns.dns[:mx] |> List.wrap() |> Enum.join("|"),
        dns_txt: dns.dns[:txt] |> List.wrap() |> Enum.join("|"),
        dns_cname: dns.dns[:cname] |> List.wrap() |> Enum.join("|"),
        dns_web_scoring: dns.scores[:dns_web_scoring] || 0,
        dns_email_scoring: dns.scores[:dns_email_scoring] || 0,
        dns_budget_scoring: dns.scores[:dns_budget_scoring] || 0,
        dns_security_scoring: dns.scores[:dns_security_scoring] || 0,
        http_status: http[:http_status],
        http_response_time: http[:http_response_time],
        http_server: http[:http_server] || "",
        http_cdn: http[:http_cdn] || "",
        http_blocked: http[:http_blocked] || "",
        http_content_type: http[:http_content_type] || "",
        http_tech: http[:http_tech] || "",
        http_tools: http[:http_tools] || "",
        http_is_js_site: http[:http_is_js_site] || "",
        http_title: http[:http_title] || "",
        http_meta_description: http[:http_meta_description] || "",
        http_pages: http[:http_pages] || "",
        http_emails: http[:http_emails] || "",
        http_error: http[:http_error] || "",
        bgp_ip: bgp[:bgp_ip] || "",
        bgp_asn_number: bgp[:bgp_asn_number] || "",
        bgp_asn_org: bgp[:bgp_asn_org] || "",
        bgp_asn_country: bgp[:bgp_asn_country] || "",
        bgp_asn_prefix: bgp[:bgp_asn_prefix] || "",
        bgp_web_scoring: bgp[:bgp_web_scoring] || 0,
        bgp_budget_scoring: bgp[:bgp_budget_scoring] || 0
      }
    end)
  end
end
