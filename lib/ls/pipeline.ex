defmodule LS.Pipeline do
  @moduledoc """
  Run pipeline stages independently or end-to-end.
  Single source of truth for per-domain HTTP enrichment and row building.

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
  alias LS.HTTP.{Client, TechDetector, AppDetector, PageExtractor, DomainFilter,
                  LanguageDetector, SchemaExtractor, TextExtractor, BusinessClassifier}
  alias LS.BGP.Resolver, as: BGPResolver
  alias LS.RDAP.Client, as: RDAPClient
  alias LS.Reputation.{Tranco, Majestic, Blocklist}
  alias LS.Revenue.Estimator, as: RevenueEstimator
  alias LS.ML.Classifier, as: MLClassifier

  # ===========================================================================
  # END-TO-END
  # ===========================================================================

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

    # Stage 3: Merge + Reputation + Classification
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

  # ===========================================================================
  # INDIVIDUAL STAGES
  # ===========================================================================

  def dns(domain) do
    case Resolver.lookup(domain) do
      {:ok, d} -> {:ok, %{dns: d, scores: %{}}}
      {:error, r} -> {:error, r}
    end
  end

  @doc """
  Full HTTP enrichment for a single domain.
  Returns a map with all http_* fields, schema, classification-ephemeral fields.
  Used by both Pipeline.run and WorkerAgent.do_http.
  """
  def http(domain, ip \\ nil) do
    ip = ip || (case Resolver.lookup(domain) do {:ok, %{a: [i | _]}} -> i; _ -> nil end)
    if is_nil(ip) do
      %{http_error: "no_ip"}
    else
      case Client.fetch(domain, ip) do
        {:ok, resp} ->
          body = resp.body || ""
          tech_result = TechDetector.detect(resp)
          app_result = AppDetector.detect(body, tech_result.tech)
          {pages, emails} = PageExtractor.extract_all(body, domain)
          title = extract_title(body)
          meta_desc = extract_meta_desc(body)
          schema_type = SchemaExtractor.extract_schema_type(body)
          og_type = SchemaExtractor.extract_og_type(body)
          h1 = TextExtractor.extract_h1(body)
          body_text = TextExtractor.extract_visible_text(body, 500)
          nav_links = TextExtractor.extract_nav_links(body)
          %{
            http_status: resp.status,
            http_response_time: resp[:elapsed_ms],
            http_blocked: tech_result.blocked,
            http_content_type: get_header(resp, "content-type"),
            http_tech: tech_result.tech |> Enum.join("|"),
            http_apps: app_result.apps |> Enum.join("|"),
            http_language: LanguageDetector.detect(body, resp.headers, title, meta_desc),
            http_title: title,
            http_meta_description: meta_desc,
            http_pages: pages || "",
            http_emails: emails || "",
            http_error: "",
            http_schema_type: schema_type,
            http_og_type: og_type,
            # Ephemeral — used by classifier, text stored separately via merge_row
            _h1: h1,
            _body_text: body_text,
            _nav_links: nav_links
          }
        {:error, reason, _} -> %{http_error: to_string(reason)}
        {:error, reason} -> %{http_error: to_string(reason)}
      end
    end
  rescue
    e -> %{http_error: "crash:#{Exception.message(e)}"}
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

  # ===========================================================================
  # ROW BUILDING — single source of truth for all 48 columns
  # ===========================================================================

  @doc """
  Build a complete enrichment row from DNS/HTTP/BGP/RDAP results.
  Used by both Pipeline.run (ctl defaults to %{}) and WorkerAgent (passes CTL data).
  """
  def merge_row(domain, dns_data, http, bgp, rdap, worker, now, ctl \\ %{}) do
    d = dns_data[:dns] || %{}

    # DNS-based tech enrichment (CNAME/IP/TXT signals)
    http_tech = http[:http_tech] || ""
    dns_tech = dns_based_tech(d, bgp)
    merged_tech = merge_tech(http_tech, dns_tech)

    # Classification
    tld = ctl[:ctl_tld] || (domain |> String.split(".") |> List.last() || "")
    h1 = http[:_h1] || ""
    body_text = http[:_body_text] || ""
    nav_links = http[:_nav_links] || ""

    classify_result = BusinessClassifier.classify(%{
      http_tech: merged_tech,
      http_apps: http[:http_apps] || "",
      http_title: http[:http_title] || "",
      http_meta_description: http[:http_meta_description] || "",
      http_pages: http[:http_pages] || "",
      http_schema_type: http[:http_schema_type] || "",
      http_og_type: http[:http_og_type] || "",
      ctl_tld: tld,
      dns_txt: d[:txt] |> List.wrap() |> Enum.join(" "),
      h1: h1,
      body_text: body_text,
      nav_links: nav_links
    })

    # Tier 2: ML classifier fallback when heuristic confidence is low
    classify_result = if classify_result.confidence < 0.55 and MLClassifier.ready?() do
      ml_text = Enum.join([http[:http_title] || "", h1, http[:http_meta_description] || "", body_text], " ")
      ml_text = String.trim(ml_text)
      if byte_size(ml_text) > 20 do
        ml = MLClassifier.classify(ml_text)
        merge_classification(classify_result, ml)
      else
        classify_result
      end
    else
      classify_result
    end

    # Reputation — pure ETS reads
    maj = Majestic.lookup(domain)
    bl = Blocklist.lookup(domain)

    %{
      enriched_at: now,
      worker: worker,
      domain: domain,
      ctl_tld: tld,
      ctl_issuer: ctl[:ctl_issuer] || "",
      ctl_subdomain_count: ctl[:ctl_subdomain_count],
      ctl_subdomains: ctl[:ctl_subdomains] || "",
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
      http_apps: http[:http_apps] || "",
      http_language: http[:http_language] || "",
      http_title: http[:http_title] || "",
      http_meta_description: http[:http_meta_description] || "",
      http_pages: http[:http_pages] || "",
      http_emails: http[:http_emails] || "",
      http_error: http[:http_error] || "",
      http_h1: h1,
      http_body_snippet: body_text,
      business_model: classify_result.business_model,
      industry: classify_result.industry,
      classification_confidence: classify_result.confidence,
      http_schema_type: http[:http_schema_type] || "",
      http_og_type: http[:http_og_type] || "",
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
    |> add_revenue_estimate()
  end

  defp add_revenue_estimate(row) do
    rev = RevenueEstimator.estimate(row)
    Map.merge(row, rev)
  end

  # ===========================================================================
  # PRIVATE — ML/heuristic merge
  # ===========================================================================

  defp merge_classification(heuristic, ml) do
    # ML overrides heuristic BM if ML confidence is decent and heuristic was empty or weak
    bm = cond do
      ml.business_model != "" and heuristic.business_model == "" -> ml.business_model
      ml.business_model != "" and ml[:ml_bm_confidence] >= 0.5 and heuristic.confidence < 0.45 -> ml.business_model
      true -> heuristic.business_model
    end

    # ML overrides heuristic industry if ML found one and heuristic didn't
    ind = cond do
      ml.industry != "" and heuristic.industry == "" -> ml.industry
      ml.industry != "" and ml[:ml_industry_confidence] >= 0.5 and heuristic.confidence < 0.45 -> ml.industry
      true -> heuristic.industry
    end

    # Confidence: take the higher of heuristic or ML
    conf = max(heuristic.confidence, ml.ml_confidence)

    %{heuristic | business_model: bm, industry: ind, confidence: conf}
  end

  # ===========================================================================
  # PRIVATE — classification helpers
  # ===========================================================================

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

  # ===========================================================================
  # PRIVATE — HTML helpers (shared by http/2)
  # ===========================================================================

  defp fmt_dt(nil), do: nil
  defp fmt_dt(dt) when is_binary(dt) do
    dt |> String.replace("T", " ") |> String.replace("Z", "") |> String.slice(0, 19)
  end
  defp fmt_dt(_), do: nil

  defp extract_title(b) when is_binary(b) do
    case Regex.run(~r/<title[^>]*>([^<]{1,500})<\/title>/is, b) do
      [_, t] -> String.trim(t) |> String.slice(0, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end
  defp extract_title(_), do: ""

  defp extract_meta_desc(b) when is_binary(b) do
    case Regex.run(~r/<meta[^>]*name\s*=\s*["']description["'][^>]*content\s*=\s*["']([^"']{1,1000})["']/is, b) do
      [_, d] -> String.trim(d) |> String.slice(0, 500)
      _ ->
        case Regex.run(~r/<meta[^>]*content\s*=\s*["']([^"']{1,1000})["'][^>]*name\s*=\s*["']description["']/is, b) do
          [_, d] -> String.trim(d) |> String.slice(0, 500)
          _ -> ""
        end
    end
  rescue
    _ -> ""
  end
  defp extract_meta_desc(_), do: ""

  defp get_header(%{headers: h}, n) when is_map(h), do: Map.get(h, n, "")
  defp get_header(%{headers: h}, n) when is_list(h) do
    case List.keyfind(h, n, 0) do
      {_, v} -> v
      nil -> ""
    end
  end
  defp get_header(_, _), do: ""

  # ===========================================================================
  # PRIVATE — DNS-based tech enrichment
  # ===========================================================================

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
end
