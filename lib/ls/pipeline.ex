defmodule LS.Pipeline do
  @moduledoc """
  Run pipeline stages independently or end-to-end.

      LS.Pipeline.run("stripe.com", verbose: true)
      LS.Pipeline.dns("stripe.com")
      LS.Pipeline.rdap("stripe.com")
      LS.Pipeline.tranco("google.com")
      LS.Pipeline.majestic("google.com")
      LS.Pipeline.blocklist("malware-site.com")
      LS.Pipeline.reputation("stripe.com")
  """

  require Logger
  alias LS.DNS.{Resolver, Scorer}
  alias LS.HTTP.{Client, TechDetector, PageExtractor, DomainFilter}
  alias LS.BGP.Resolver, as: BGPResolver
  alias LS.BGP.Scorer, as: BGPScorer
  alias LS.RDAP.Client, as: RDAPClient
  alias LS.RDAP.Scorer, as: RDAPScorer
  alias LS.Reputation.{Tranco, Majestic, Blocklist}

  def run(domains, opts \\ []) when is_binary(domains) or is_list(domains) do
    domains = List.wrap(domains)
    verbose = Keyword.get(opts, :verbose, false)
    insert = Keyword.get(opts, :insert, false)
    worker = Node.self() |> Atom.to_string()

    vlog(verbose, "⏳ DNS (#{length(domains)})...")
    {dns_us, dns_res} = :timer.tc(fn ->
      Enum.map(domains, fn d -> case dns(d) do {:ok, data} -> {d, data}; _ -> {d, empty_dns()} end end) |> Map.new()
    end)
    vlog(verbose, "✅ DNS #{div(dns_us, 1000)}ms — #{map_size(dns_res)} resolved")

    {http_cands, bgp_cands} = classify(dns_res)
    rdap_cands = dns_res |> Enum.filter(fn {_, d} -> d.dns[:a] |> List.wrap() |> List.first() end) |> Enum.map(fn {d, _} -> d end)
    vlog(verbose, "   HTTP: #{length(http_cands)} | BGP: #{length(bgp_cands)} | RDAP: #{length(rdap_cands)}")

    vlog(verbose, "⏳ HTTP...")
    {http_us, http_res} = :timer.tc(fn -> http_cands |> Enum.map(fn {d, ip} -> {d, http(d, ip)} end) |> Map.new() end)
    vlog(verbose, "✅ HTTP #{div(http_us, 1000)}ms")

    {bgp_us, bgp_res} = :timer.tc(fn -> run_bgp(bgp_cands) end)
    vlog(verbose, "✅ BGP #{div(bgp_us, 1000)}ms")

    vlog(verbose, "⏳ RDAP...")
    {rdap_us, rdap_res} = :timer.tc(fn ->
      Enum.reduce(rdap_cands, %{}, fn d, acc ->
        case rdap(d) do {:ok, data} -> Map.put(acc, d, data); _ -> acc end
      end)
    end)
    vlog(verbose, "✅ RDAP #{div(rdap_us, 1000)}ms — #{map_size(rdap_res)} resolved")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)
    rows = Enum.map(domains, fn d ->
      merge_row(d, Map.get(dns_res, d, empty_dns()), Map.get(http_res, d, %{}),
                Map.get(bgp_res, d, %{}), Map.get(rdap_res, d, %{}), worker, now)
    end)

    if insert, do: (vlog(verbose, "⏳ Inserting..."); LS.Cluster.Inserter.insert(rows); vlog(verbose, "✅ Inserted"))
    if verbose, do: IO.puts("\n═══ DONE #{div(dns_us + http_us + bgp_us + rdap_us, 1000)}ms ═══")
    case rows do [single] -> single; many -> many end
  end

  def dns(domain) do
    case Resolver.lookup(domain) do
      {:ok, d} -> {:ok, %{dns: d, scores: Scorer.score(%{domain: domain, dns: d})}}
      {:error, r} -> {:error, r}
    end
  end

  def http(domain, ip \\ nil) do
    ip = ip || (case Resolver.lookup(domain) do {:ok, %{a: [i | _]}} -> i; _ -> nil end)
    unless ip, do: throw(%{http_error: "no_ip"})
    case Client.fetch(domain, ip) do
      {:ok, resp} -> tech = TechDetector.detect(resp); body = resp.body || ""
        {pages, emails} = PageExtractor.extract_all(body, domain)
        %{http_status: resp.status, http_tech: tech[:tech] |> List.wrap() |> Enum.join("|"),
          http_tools: tech[:tools] |> List.wrap() |> Enum.join("|"),
          http_title: extract_title(body), http_pages: pages || "", http_emails: emails || "", http_error: ""}
      {:error, r, _} -> %{http_error: to_string(r)}
      {:error, r} -> %{http_error: to_string(r)}
    end
  catch val -> val
  end

  def bgp(ip) when is_binary(ip) do
    case GenServer.call(BGPResolver, {:lookup, ip}, 30_000) do
      {:ok, data} -> {:ok, Map.merge(data, BGPScorer.score(data))}; e -> e
    end
  end

  def rdap(domain) do
    case RDAPClient.lookup(domain) do
      {:ok, data} -> {:ok, Map.merge(data, RDAPScorer.score(data))}; e -> e
    end
  end

  def tranco(domain), do: Tranco.lookup(domain)
  def majestic(domain), do: Majestic.lookup(domain)
  def blocklist(domain), do: Blocklist.lookup(domain)

  @doc "All reputation data for a domain."
  def reputation(domain) do
    %{tranco_rank: tranco(domain), majestic: majestic(domain), blocklist: blocklist(domain)}
  end

  def should_crawl?(domain) do
    case dns(domain) do
      {:ok, data} ->
        mx = data.dns[:mx] |> List.wrap() |> Enum.join("|")
        txt = data.dns[:txt] |> List.wrap() |> Enum.join(" ")
        ip = data.dns[:a] |> List.wrap() |> List.first()
        %{would_crawl: (ip && DomainFilter.should_crawl?(domain, mx, txt)) || false,
          has_a_record: ip != nil, has_mx: mx != "", has_spf: String.contains?(txt, "spf"),
          blocked: Blocklist.blocked?(domain), tranco_rank: tranco(domain)}
      {:error, r} -> %{would_crawl: false, error: r}
    end
  end

  defp empty_dns do
    %{dns: %{a: [], aaaa: [], mx: [], txt: [], cname: []},
      scores: %{dns_web_scoring: 0, dns_email_scoring: 0, dns_budget_scoring: 0, dns_security_scoring: 0}}
  end

  defp classify(dns_res) do
    Enum.reduce(dns_res, {[], []}, fn {d, data}, {ha, ba} ->
      ip = data.dns[:a] |> List.wrap() |> List.first()
      ba = if ip && ip != "", do: [{d, ip} | ba], else: ba
      mx = data.dns[:mx] |> List.wrap() |> Enum.join("|")
      txt = data.dns[:txt] |> List.wrap() |> Enum.join(" ")
      ha = if ip && ip != "" && DomainFilter.should_crawl?(d, mx, txt), do: [{d, ip} | ha], else: ha
      {ha, ba}
    end)
  end

  defp run_bgp(cands) do
    ips = Enum.map(cands, fn {_, ip} -> ip end) |> Enum.uniq()
    case GenServer.call(BGPResolver, {:lookup_batch, ips}, 60_000) do
      {:ok, asn_map} ->
        Enum.reduce(cands, %{}, fn {d, ip}, acc ->
          case Map.get(asn_map, ip) do
            nil -> acc
            a ->
              sc = BGPScorer.score(a)
              Map.put(acc, d, %{bgp_ip: ip, bgp_asn_number: a.asn || "", bgp_asn_org: a.org || "",
                bgp_asn_country: a.country || "", bgp_asn_prefix: a.prefix || "",
                bgp_web_scoring: sc.bgp_web_scoring, bgp_budget_scoring: sc.bgp_budget_scoring})
          end
        end)
      _ -> %{}
    end
  end

  defp merge_row(domain, dns_data, http, bgp, rdap, worker, now) do
    d = dns_data[:dns] || %{}
    sc = dns_data[:scores] || %{}
    maj = Majestic.lookup(domain)
    bl = Blocklist.lookup(domain)
    %{
      enriched_at: now, worker: worker, domain: domain,
      ctl_tld: domain |> String.split(".") |> List.last() || "", ctl_issuer: "",
      ctl_subdomain_count: 0, ctl_subdomains: "",
      ctl_web_scoring: 0, ctl_budget_scoring: 0, ctl_security_scoring: 0,
      dns_a: d[:a] |> List.wrap() |> Enum.join("|"),
      dns_aaaa: d[:aaaa] |> List.wrap() |> Enum.join("|"),
      dns_mx: d[:mx] |> List.wrap() |> Enum.join("|"),
      dns_txt: d[:txt] |> List.wrap() |> Enum.join("|"),
      dns_cname: d[:cname] |> List.wrap() |> Enum.join("|"),
      dns_web_scoring: sc[:dns_web_scoring] || 0,
      dns_email_scoring: sc[:dns_email_scoring] || 0,
      dns_budget_scoring: sc[:dns_budget_scoring] || 0,
      dns_security_scoring: sc[:dns_security_scoring] || 0,
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
      bgp_budget_scoring: bgp[:bgp_budget_scoring] || 0,
      rdap_domain_created_at: fmt_dt(rdap[:domain_created_at]),
      rdap_domain_expires_at: fmt_dt(rdap[:domain_expires_at]),
      rdap_domain_updated_at: fmt_dt(rdap[:domain_updated_at]),
      rdap_registrar: rdap[:registrar] || "",
      rdap_registrar_iana_id: rdap[:registrar_iana_id] || "",
      rdap_nameservers: rdap[:nameservers] || "",
      rdap_status: rdap[:status] || "",
      rdap_dnssec: rdap[:dnssec] || "",
      rdap_age_scoring: rdap[:rdap_age_scoring] || 0,
      rdap_registrar_scoring: rdap[:rdap_registrar_scoring] || 0,
      rdap_error: "",
      tranco_rank: Tranco.lookup(domain),
      majestic_rank: if(maj, do: maj.rank, else: nil),
      majestic_ref_subnets: if(maj, do: maj.ref_subnets, else: nil),
      is_malware: if(bl == :malware, do: "true", else: ""),
      is_phishing: if(bl == :phishing, do: "true", else: ""),
      is_disposable_email: if(bl == :disposable, do: "true", else: "")
    }
  end

  defp fmt_dt(nil), do: nil
  defp fmt_dt(dt) when is_binary(dt) do
    dt |> String.replace("T", " ") |> String.replace("Z", "") |> String.slice(0, 19)
  end
  defp fmt_dt(_), do: nil

  defp extract_title(b) do
    case Regex.run(~r/<title[^>]*>([^<]{1,500})<\/title>/is, b) do
      [_, t] -> String.trim(t) |> String.slice(0, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp vlog(true, msg), do: IO.puts(msg)
  defp vlog(_, _), do: :ok
end
