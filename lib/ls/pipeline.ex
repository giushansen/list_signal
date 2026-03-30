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
  alias LS.DNS.Resolver
  alias LS.HTTP.{Client, TechDetector, PageExtractor, DomainFilter}
  alias LS.BGP.Resolver, as: BGPResolver
  alias LS.RDAP.Client, as: RDAPClient
  
  alias LS.Reputation.{Tranco, Majestic, Blocklist}

  def run(domains, opts \\ []) when is_binary(domains) or is_list(domains) do
    domains = List.wrap(domains)
    _verbose = Keyword.get(opts, :verbose, false)
    insert = Keyword.get(opts, :insert, false)
    worker = Node.self() |> Atom.to_string()

    Logger.info("[PIPELINE] Starting for #{inspect(domains)}")

    # Stage 1: DNS
    Logger.info("[PIPELINE][DNS] Starting for #{length(domains)} domains")
    {dns_us, dns_res} = :timer.tc(fn ->
      Enum.map(domains, fn d ->
        case dns(d) do
          {:ok, data} ->
            Logger.debug("[PIPELINE][DNS] #{d} OK — A:#{length(data.dns[:a] || [])} MX:#{length(data.dns[:mx] || [])}")
            {d, data}
          {:error, reason} ->
            Logger.warning("[PIPELINE][DNS] #{d} FAILED: #{inspect(reason)}")
            {d, empty_dns()}
        end
      end) |> Map.new()
    end)
    Logger.info("[PIPELINE][DNS] Done in #{div(dns_us, 1000)}ms — #{map_size(dns_res)} resolved")

    {http_cands, bgp_cands} = classify(dns_res)
    rdap_cands = dns_res |> Enum.filter(fn {_, d} -> d.dns[:a] |> List.wrap() |> List.first() end) |> Enum.map(fn {d, _} -> d end)
    Logger.info("[PIPELINE] Candidates — HTTP:#{length(http_cands)} BGP:#{length(bgp_cands)} RDAP:#{length(rdap_cands)}")

    # Stage 2: HTTP + BGP + RDAP in parallel
    Logger.info("[PIPELINE][HTTP] Starting for #{length(http_cands)} candidates")
    http_task = Task.async(fn ->
      http_cands |> Enum.map(fn {d, ip} ->
        result = http(d, ip)
        Logger.debug("[PIPELINE][HTTP] #{d} → status:#{result[:http_status]} tech:#{result[:http_tech] || "none"} error:#{result[:http_error] || "none"}")
        {d, result}
      end) |> Map.new()
    end)

    Logger.info("[PIPELINE][BGP] Starting for #{length(bgp_cands)} IPs")
    bgp_task = Task.async(fn ->
      result = run_bgp(bgp_cands)
      Logger.debug("[PIPELINE][BGP] Got #{map_size(result)} results")
      result
    end)

    Logger.info("[PIPELINE][RDAP] Starting for #{length(rdap_cands)} domains")
    rdap_task = Task.async(fn ->
      Enum.reduce(rdap_cands, %{}, fn d, acc ->
        case rdap(d) do
          {:ok, data} ->
            Logger.debug("[PIPELINE][RDAP] #{d} OK — registrar:#{data[:registrar] || "?"}")
            Map.put(acc, d, data)
          {:error, reason} ->
            Logger.debug("[PIPELINE][RDAP] #{d} FAILED: #{inspect(reason)}")
            acc
        end
      end)
    end)

    # Await all with timeouts
    http_res = Task.await(http_task, 30_000)
    Logger.info("[PIPELINE][HTTP] Done — #{map_size(http_res)} results")

    bgp_res = Task.await(bgp_task, 30_000)
    Logger.info("[PIPELINE][BGP] Done — #{map_size(bgp_res)} results")

    rdap_res = Task.await(rdap_task, 20_000)
    Logger.info("[PIPELINE][RDAP] Done — #{map_size(rdap_res)} results")

    # Stage 3: Merge + Reputation
    Logger.info("[PIPELINE][REPUTATION] Merging rows — http_keys:#{inspect(Map.keys(http_res |> Map.values() |> List.first() || %{}))} bgp_keys:#{inspect(Map.keys(bgp_res |> Map.values() |> List.first() || %{}))} rdap_keys:#{inspect(Map.keys(rdap_res |> Map.values() |> List.first() || %{}))}")
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)
    rows = Enum.map(domains, fn d ->
      merge_row(d, Map.get(dns_res, d, empty_dns()), Map.get(http_res, d, %{}),
                Map.get(bgp_res, d, %{}), Map.get(rdap_res, d, %{}), worker, now)
    end)

    if insert do
      Logger.info("[PIPELINE][INSERT] Inserting #{length(rows)} rows")
      LS.Cluster.Inserter.insert(rows)
      Logger.info("[PIPELINE][INSERT] Done")
    end

    total_ms = div(dns_us, 1000)
    Logger.info("[PIPELINE] COMPLETE for #{inspect(domains)} in #{total_ms}ms+parallel")
    case rows do [single] -> single; many -> many end
  end

  def dns(domain) do
    case Resolver.lookup(domain) do
      {:ok, d} -> {:ok, %{dns: d, scores: %{}}}
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
          http_title: extract_title(body), http_pages: pages || "", http_emails: emails || "", http_error: ""}
      {:error, r, _} -> %{http_error: to_string(r)}
      {:error, r} -> %{http_error: to_string(r)}
    end
  catch val -> val
  end

  def bgp(ip) when is_binary(ip) do
    case GenServer.call(BGPResolver, {:lookup, ip}, 30_000) do
      {:ok, result} -> {:ok, result}; {:error, r} -> {:error, r}
    end
  end

  def rdap(domain) do
    case RDAPClient.lookup(domain) do
      {:ok, data} -> {:ok, data}; e -> e
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
    %{dns: %{a: [], aaaa: [], mx: [], txt: [], cname: []}}
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
              Map.put(acc, d, %{bgp_ip: ip, bgp_asn_number: a.asn || "", bgp_asn_org: a.org || "",
                bgp_asn_country: a.country || "", bgp_asn_prefix: a.prefix || ""})
          end
        end)
      _ -> %{}
    end
  end

  defp merge_row(domain, dns_data, http, bgp, rdap, worker, now) do
    d = dns_data[:dns] || %{}
    _sc = dns_data[:scores] || %{}
    maj = Majestic.lookup(domain)
    bl = Blocklist.lookup(domain)

    # Enrich tech with DNS/IP signals when HTTP detection missed them
    http_tech = http[:http_tech] || ""
    dns_tech = dns_based_tech(d, bgp)
    merged_tech = merge_tech(http_tech, dns_tech)

    %{
      enriched_at: now, worker: worker, domain: domain,
      ctl_tld: domain |> String.split(".") |> List.last() || "", ctl_issuer: "",
      ctl_subdomain_count: 0, ctl_subdomains: "",
      dns_a: d[:a] |> List.wrap() |> Enum.join("|"),
      dns_aaaa: d[:aaaa] |> List.wrap() |> Enum.join("|"),
      dns_mx: d[:mx] |> List.wrap() |> Enum.join("|"),
      dns_txt: d[:txt] |> List.wrap() |> Enum.join("|"),
      dns_cname: d[:cname] |> List.wrap() |> Enum.join("|"),
      http_status: http[:http_status],
      http_response_time: http[:http_response_time],
      http_blocked: http[:http_blocked] || "",
      http_content_type: http[:http_content_type] || "",
      http_tech: merged_tech,
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
      rdap_domain_created_at: fmt_dt(rdap[:domain_created_at]),
      rdap_domain_expires_at: fmt_dt(rdap[:domain_expires_at]),
      rdap_domain_updated_at: fmt_dt(rdap[:domain_updated_at]),
      rdap_registrar: rdap[:registrar] || "",
      rdap_registrar_iana_id: rdap[:registrar_iana_id] || "",
      rdap_nameservers: rdap[:nameservers] || "",
      rdap_status: rdap[:status] || "",
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

  # Shopify IP ranges (23.227.38.0/23 and 23.227.36.0/23)
  @shopify_prefixes ["23.227.38.", "23.227.39.", "23.227.36.", "23.227.37."]

  defp dns_based_tech(dns, bgp) do
    cnames = dns[:cname] |> List.wrap() |> Enum.join(" ") |> String.downcase()
    ips = dns[:a] |> List.wrap()
    txt = dns[:txt] |> List.wrap() |> Enum.join(" ") |> String.downcase()
    mx = dns[:mx] |> List.wrap() |> Enum.join(" ") |> String.downcase()
    asn_org = (bgp[:bgp_asn_org] || "") |> String.downcase()

    techs = []
    # Shopify: CNAME to shops.myshopify.com or Shopify IP ranges
    techs = if String.contains?(cnames, "myshopify.com") or
               Enum.any?(ips, fn ip -> Enum.any?(@shopify_prefixes, &String.starts_with?(ip, &1)) end),
            do: ["Shopify" | techs], else: techs
    # Cloudflare: common ASN org
    techs = if String.contains?(asn_org, "cloudflare"), do: ["Cloudflare" | techs], else: techs
    # Google Workspace: MX records
    techs = if String.contains?(mx, "google") or String.contains?(mx, "googlemail"),
            do: ["Google Workspace" | techs], else: techs
    # Microsoft 365: MX records
    techs = if String.contains?(mx, "outlook") or String.contains?(mx, "microsoft"),
            do: ["Microsoft 365" | techs], else: techs
    # SPF-based detection
    techs = if String.contains?(txt, "spf.protection.outlook"), do: ["Microsoft 365" | techs], else: techs
    # Verification TXT records
    techs = if String.contains?(txt, "google-site-verification"), do: ["Google Search Console" | techs], else: techs
    techs = if String.contains?(txt, "facebook-domain-verification"), do: ["Meta Pixel" | techs], else: techs

    techs |> Enum.uniq()
  end

  defp merge_tech(http_tech_str, dns_techs) do
    existing = http_tech_str |> String.split("|") |> Enum.reject(&(&1 == "")) |> MapSet.new(&String.downcase/1)
    new = Enum.reject(dns_techs, fn t -> MapSet.member?(existing, String.downcase(t)) end)
    all = (http_tech_str |> String.split("|") |> Enum.reject(&(&1 == ""))) ++ new
    Enum.join(all, "|")
  end

  defp extract_title(b) do
    case Regex.run(~r/<title[^>]*>([^<]{1,500})<\/title>/is, b) do
      [_, t] -> String.trim(t) |> String.slice(0, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end

end
