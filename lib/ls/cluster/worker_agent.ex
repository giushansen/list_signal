defmodule LS.Cluster.WorkerAgent do
  @moduledoc """
  Worker agent — runs on each worker node.

  Connects to master, pulls domain batches, runs DNS → HTTP + BGP enrichment,
  returns completed rows to master for ClickHouse insertion.

  No files. Everything in memory.

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

  @batch_size 1000
  @dns_concurrency 500
  @http_timeout 25_000
  @reconnect_interval_ms 10_000
  @empty_queue_wait_ms 30_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    master_node = System.get_env("LS_MASTER", "master@10.0.0.1") |> String.to_atom()
    http_concurrency = System.get_env("LS_HTTP_CONCURRENCY", "100") |> String.to_integer()

    LS.HTTP.DomainFilter.load_tlds()

    state = %{
      master_node: master_node,
      connected: false,
      http_concurrency: http_concurrency,
      total_enriched: 0,
      total_batches: 0,
      current_batch: nil,
      start_time: System.monotonic_time(:second)
    }

    send(self(), :connect_and_work)
    Logger.info("🔧 WorkerAgent starting (master: #{master_node}, HTTP concurrency: #{http_concurrency})")
    {:ok, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time
    stats = %{
      master_node: state.master_node,
      connected: state.connected,
      http_concurrency: state.http_concurrency,
      total_enriched: state.total_enriched,
      total_batches: state.total_batches,
      current_batch: state.current_batch,
      domains_per_sec: if(uptime > 0, do: Float.round(state.total_enriched / uptime, 2), else: 0.0),
      uptime_seconds: uptime
    }
    {:reply, stats, state}
  end

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

  @impl true
  def handle_info(:pull_work, state) do
    queue = {LS.Cluster.WorkQueue, state.master_node}

    try do
      case GenServer.call(queue, {:dequeue, @batch_size}, 15_000) do
        {:ok, batch_id, domains} ->
          Logger.info("📦 Batch #{batch_id}: #{length(domains)} domains")

          results = enrich_batch(domains, state.http_concurrency)
          Logger.info("✅ Batch #{batch_id}: #{length(results)} enriched rows")

          GenServer.cast(queue, {:complete, batch_id, results})

          state = %{state |
            total_enriched: state.total_enriched + length(results),
            total_batches: state.total_batches + 1,
            current_batch: nil
          }
          send(self(), :pull_work)
          {:noreply, state}

        {:empty, []} ->
          Logger.debug("📭 Queue empty, waiting #{div(@empty_queue_wait_ms, 1000)}s...")
          Process.send_after(self(), :pull_work, @empty_queue_wait_ms)
          {:noreply, %{state | current_batch: nil}}
      end
    catch
      :exit, reason ->
        Logger.warning("⚠️  Lost connection to master: #{inspect(reason)}")
        Process.send_after(self(), :connect_and_work, @reconnect_interval_ms)
        {:noreply, %{state | connected: false, current_batch: nil}}
    end
  end

  # ==========================================================================
  # ENRICHMENT — all in-memory, no files
  # ==========================================================================

  defp enrich_batch(domains, http_concurrency) do
    worker_name = Node.self() |> Atom.to_string()

    # 1. DNS (all domains)
    dns_results = enrich_dns(domains)

    # 2. Classify: which get HTTP, which get BGP
    {http_candidates, bgp_candidates} = classify(dns_results)

    # 3. HTTP (filtered, slow)
    http_results = enrich_http(http_candidates, http_concurrency)

    # 4. BGP (batched)
    bgp_results = enrich_bgp(bgp_candidates)

    # 5. Merge
    merge_results(domains, dns_results, http_results, bgp_results, worker_name)
  end

  defp enrich_dns(domains) do
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
      max_concurrency: @dns_concurrency, timeout: 15_000,
      on_timeout: :kill_task, ordered: false
    )
    |> Enum.reduce(%{}, fn
      {:ok, {domain, result}}, acc -> Map.put(acc, domain, result)
      {:exit, _}, acc -> acc
    end)
  end

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
      {:ok, response, _raw} ->
        tech = TechDetector.detect(response)
        page = PageExtractor.extract_all(response)
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
          http_title: page[:title] || "",
          http_meta_description: page[:meta_description] || "",
          http_pages: page[:pages] |> List.wrap() |> Enum.join("|"),
          http_emails: page[:emails] |> List.wrap() |> Enum.join("|"),
          http_error: ""
        }
      {:error, reason, _} -> %{http_error: to_string(reason)}
    end
  rescue
    e -> %{http_error: "crash:#{Exception.message(e)}"}
  end

  defp get_header(%{headers: h}, name) when is_map(h), do: Map.get(h, name, "")
  defp get_header(%{headers: h}, name) when is_list(h) do
    case List.keyfind(h, name, 0) do
      {_, v} -> v
      nil -> ""
    end
  end
  defp get_header(_, _), do: ""

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
