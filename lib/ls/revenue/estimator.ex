defmodule LS.Revenue.Estimator do
  @moduledoc """
  Revenue bracket estimation from domain intelligence signals.

  Additive scoring system: each signal contributes points toward one or more
  revenue brackets. Points are summed per bracket, normalized to probabilities
  via softmax, and the winner is selected if confidence exceeds the threshold.

  5 Revenue Brackets:
    micro         = <$1M       (~1-10 employees)
    small         = $1M-$10M   (~10-50 employees)
    mid_market    = $10M-$100M (~50-500 employees)
    enterprise    = $100M-$1B  (~500-5000 employees)
    large_enterprise = $1B+    (~5000+ employees)

  Every scoring decision is recorded in the evidence trail for transparency.
  """

  @brackets [:micro, :small, :mid_market, :enterprise, :large_enterprise]
  @min_confidence 0.40
  @min_evidence_count 3

  @empty_result %{
    estimated_revenue: "",
    estimated_employees: "",
    revenue_confidence: 0.0,
    revenue_evidence: ""
  }

  # RPE (revenue-per-employee) by business model for employee estimation
  @rpe_by_industry %{
    "SaaS" => 200_000,
    "Ecommerce" => 120_000,
    "Agency" => 130_000,
    "Consulting" => 150_000,
    "Media" => 100_000,
    "Education" => 40_000,
    "Marketplace" => 150_000,
    "Newsletter" => 200_000,
    "Community" => 80_000,
    "Directory" => 100_000,
    "Tool" => 180_000
  }

  @bracket_labels %{
    micro: "<$1M",
    small: "$1M-$10M",
    mid_market: "$10M-$100M",
    enterprise: "$100M-$1B",
    large_enterprise: "$1B+"
  }

  @bracket_midpoints %{
    micro: 300_000,
    small: 3_000_000,
    mid_market: 30_000_000,
    enterprise: 300_000_000,
    large_enterprise: 3_000_000_000
  }

  @employee_labels %{
    micro: "1-10",
    small: "11-50",
    mid_market: "51-500",
    enterprise: "501-5000",
    large_enterprise: "5001+"
  }

  # =========================================================================
  # PUBLIC API
  # =========================================================================

  @doc """
  Estimate revenue bracket from an enrichment signals map.

  Accepts the same signals map that merge_row produces (all column fields).
  Returns a map with:
    - estimated_revenue: bracket label string (e.g., "$1M-$10M")
    - estimated_employees: employee range string (e.g., "11-50")
    - revenue_confidence: float 0.0-1.0
    - revenue_evidence: pipe-separated evidence strings
  """
  def estimate(signals) when is_map(signals) do
    # No HTTP response = no website = can't estimate revenue.
    # Infrastructure/DNS domains (ddns.net, azure.net, etc.) have high Tranco
    # ranks from subdomain traffic but are not businesses.
    http_status = signals[:http_status]
    has_website = http_status != nil and http_status != ""

    if not has_website do
      @empty_result
    else
      scores = %{micro: 0, small: 0, mid_market: 0, enterprise: 0, large_enterprise: 0}
      evidence = []

      {scores, evidence} = signal_tranco_rank(signals, scores, evidence)
      {scores, evidence} = signal_majestic_rank(signals, scores, evidence)
      {scores, evidence} = signal_registrar(signals, scores, evidence)
      {scores, evidence} = signal_ssl_issuer(signals, scores, evidence)
      {scores, evidence} = signal_email_provider(signals, scores, evidence)
      {scores, evidence} = signal_spf_includes(signals, scores, evidence)
      {scores, evidence} = signal_dmarc_policy(signals, scores, evidence)
      {scores, evidence} = signal_marketing_automation(signals, scores, evidence)
      {scores, evidence} = signal_subdomain_count(signals, scores, evidence)
      {scores, evidence} = signal_tech_count(signals, scores, evidence)
      {scores, evidence} = signal_app_count(signals, scores, evidence)
      {scores, evidence} = signal_cdn_tier(signals, scores, evidence)
      {scores, evidence} = signal_cms_tier(signals, scores, evidence)
      {scores, evidence} = signal_enterprise_pages(signals, scores, evidence)
      {scores, evidence} = signal_domain_age(signals, scores, evidence)
      {scores, evidence} = signal_hosting_tier(signals, scores, evidence)
      {scores, evidence} = signal_email_security(signals, scores, evidence)
      {scores, evidence} = signal_enterprise_tools(signals, scores, evidence)
      {scores, evidence} = signal_subdomain_names(signals, scores, evidence)
      {scores, evidence} = signal_nameservers(signals, scores, evidence)
      {scores, evidence} = signal_dns_load_balancing(signals, scores, evidence)
      {scores, evidence} = signal_structured_data(signals, scores, evidence)
      {scores, evidence} = signal_title_keywords(signals, scores, evidence)
      {scores, evidence} = signal_contact_emails(signals, scores, evidence)
      {scores, evidence} = signal_industry_prior(signals, scores, evidence)

      pick_result(scores, evidence, signals)
    end
  rescue
    _ -> @empty_result
  end

  def estimate(_), do: @empty_result

  @doc "Get the bracket label for a bracket atom."
  def bracket_label(bracket), do: Map.get(@bracket_labels, bracket, "")

  @doc "Get the employee label for a bracket atom."
  def employee_label(bracket), do: Map.get(@employee_labels, bracket, "")

  # =========================================================================
  # SIGNAL 1 — Traffic Rank (Tranco) — strongest single predictor
  # =========================================================================

  defp signal_tranco_rank(signals, scores, evidence) do
    rank = get_int(signals, :tranco_rank)
    cond do
      is_nil(rank) ->
        {add(scores, :micro, 3), evidence}

      rank <= 1_000 ->
        {add(scores, :large_enterprise, 20) |> add(:enterprise, 8),
         [{"tranco", "top_1k:#{rank}", :large_enterprise} | evidence]}

      rank <= 10_000 ->
        {add(scores, :enterprise, 15) |> add(:large_enterprise, 5) |> add(:mid_market, 3),
         [{"tranco", "top_10k:#{rank}", :enterprise} | evidence]}

      rank <= 100_000 ->
        {add(scores, :mid_market, 10) |> add(:enterprise, 4) |> add(:small, 2),
         [{"tranco", "top_100k:#{rank}", :mid_market} | evidence]}

      rank <= 500_000 ->
        {add(scores, :small, 6) |> add(:mid_market, 3),
         [{"tranco", "top_500k:#{rank}", :small} | evidence]}

      rank <= 1_000_000 ->
        {add(scores, :small, 4) |> add(:micro, 2),
         [{"tranco", "top_1m:#{rank}", :small} | evidence]}

      true ->
        {add(scores, :micro, 4) |> add(:small, 2),
         [{"tranco", "beyond_1m:#{rank}", :micro} | evidence]}
    end
  end

  # =========================================================================
  # SIGNAL 2 — Majestic Rank (link authority)
  # =========================================================================

  defp signal_majestic_rank(signals, scores, evidence) do
    rank = get_int(signals, :majestic_rank)
    ref_subnets = get_int(signals, :majestic_ref_subnets)

    {scores, evidence} = cond do
      is_nil(rank) -> {scores, evidence}

      rank <= 5_000 ->
        {add(scores, :large_enterprise, 8) |> add(:enterprise, 4),
         [{"majestic", "top_5k:#{rank}", :large_enterprise} | evidence]}

      rank <= 50_000 ->
        {add(scores, :enterprise, 6) |> add(:mid_market, 3),
         [{"majestic", "top_50k:#{rank}", :enterprise} | evidence]}

      rank <= 500_000 ->
        {add(scores, :mid_market, 4) |> add(:small, 2),
         [{"majestic", "top_500k:#{rank}", :mid_market} | evidence]}

      true -> {scores, evidence}
    end

    cond do
      is_nil(ref_subnets) -> {scores, evidence}

      ref_subnets >= 5_000 ->
        {add(scores, :enterprise, 5),
         [{"ref_subnets", "#{ref_subnets}", :enterprise} | evidence]}

      ref_subnets >= 500 ->
        {add(scores, :mid_market, 3),
         [{"ref_subnets", "#{ref_subnets}", :mid_market} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 3 — Registrar (RDAP)
  # MarkMonitor/CSC nearly diagnostic for Fortune 500
  # =========================================================================

  defp signal_registrar(signals, scores, evidence) do
    registrar = get_str(signals, :rdap_registrar) |> String.downcase()

    cond do
      registrar == "" -> {scores, evidence}

      String.contains?(registrar, "markmonitor") ->
        {add(scores, :large_enterprise, 12) |> add(:enterprise, 6),
         [{"registrar", "MarkMonitor", :large_enterprise} | evidence]}

      String.contains?(registrar, "csc corporate") or String.contains?(registrar, "corporation service") ->
        {add(scores, :large_enterprise, 10) |> add(:enterprise, 5),
         [{"registrar", "CSC", :large_enterprise} | evidence]}

      String.contains?(registrar, "network solutions") ->
        {add(scores, :enterprise, 6) |> add(:mid_market, 3),
         [{"registrar", "NetworkSolutions", :enterprise} | evidence]}

      String.contains?(registrar, "godaddy") ->
        {add(scores, :micro, 4) |> add(:small, 3),
         [{"registrar", "GoDaddy", :micro} | evidence]}

      String.contains?(registrar, "namecheap") ->
        {add(scores, :micro, 4) |> add(:small, 3),
         [{"registrar", "Namecheap", :micro} | evidence]}

      String.contains?(registrar, "tucows") ->
        {add(scores, :small, 3) |> add(:micro, 2),
         [{"registrar", "Tucows", :small} | evidence]}

      String.contains?(registrar, "google") or String.contains?(registrar, "squarespace") ->
        {add(scores, :small, 3) |> add(:micro, 2),
         [{"registrar", "Google/Squarespace", :small} | evidence]}

      String.contains?(registrar, "cloudflare") ->
        {add(scores, :small, 3) |> add(:mid_market, 2),
         [{"registrar", "Cloudflare", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 4 — SSL Certificate Issuer
  # =========================================================================

  defp signal_ssl_issuer(signals, scores, evidence) do
    issuer = get_str(signals, :ctl_issuer) |> String.downcase()

    cond do
      issuer == "" -> {scores, evidence}

      String.contains?(issuer, "digicert") ->
        {add(scores, :enterprise, 10) |> add(:large_enterprise, 5) |> add(:mid_market, 3),
         [{"ssl_issuer", "DigiCert", :enterprise} | evidence]}

      String.contains?(issuer, "sectigo") or String.contains?(issuer, "comodo") ->
        {add(scores, :mid_market, 3) |> add(:small, 2),
         [{"ssl_issuer", "Sectigo", :mid_market} | evidence]}

      String.contains?(issuer, "globalsign") ->
        {add(scores, :enterprise, 5) |> add(:mid_market, 3),
         [{"ssl_issuer", "GlobalSign", :enterprise} | evidence]}

      String.contains?(issuer, "entrust") ->
        {add(scores, :enterprise, 6) |> add(:mid_market, 2),
         [{"ssl_issuer", "Entrust", :enterprise} | evidence]}

      String.contains?(issuer, "let's encrypt") or String.contains?(issuer, "letsencrypt") or
      String.contains?(issuer, "r3") or String.contains?(issuer, "r10") or String.contains?(issuer, "r11") ->
        {add(scores, :micro, 4) |> add(:small, 3),
         [{"ssl_issuer", "LetsEncrypt", :micro} | evidence]}

      String.contains?(issuer, "amazon") ->
        {add(scores, :small, 2) |> add(:mid_market, 2),
         [{"ssl_issuer", "Amazon", :small} | evidence]}

      String.contains?(issuer, "google") ->
        {add(scores, :small, 2) |> add(:micro, 1),
         [{"ssl_issuer", "Google", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 5 — Email Provider (MX records)
  # =========================================================================

  defp signal_email_provider(signals, scores, evidence) do
    mx = get_str(signals, :dns_mx) |> String.downcase()

    cond do
      mx == "" ->
        {add(scores, :micro, 3), evidence}

      String.contains?(mx, "pphosted") or String.contains?(mx, "proofpoint") ->
        {add(scores, :enterprise, 12) |> add(:large_enterprise, 5),
         [{"mx", "Proofpoint", :enterprise} | evidence]}

      String.contains?(mx, "mimecast") ->
        {add(scores, :enterprise, 8) |> add(:mid_market, 4),
         [{"mx", "Mimecast", :enterprise} | evidence]}

      String.contains?(mx, "barracuda") ->
        {add(scores, :mid_market, 5) |> add(:enterprise, 4),
         [{"mx", "Barracuda", :mid_market} | evidence]}

      String.contains?(mx, "outlook") or String.contains?(mx, "microsoft") or
      String.contains?(mx, "protection.outlook") ->
        {add(scores, :mid_market, 4) |> add(:enterprise, 3) |> add(:small, 2),
         [{"mx", "Microsoft365", :mid_market} | evidence]}

      String.contains?(mx, "google") or String.contains?(mx, "googlemail") or
      String.contains?(mx, "aspmx") ->
        {add(scores, :small, 4) |> add(:mid_market, 2) |> add(:micro, 1),
         [{"mx", "GoogleWorkspace", :small} | evidence]}

      String.contains?(mx, "zoho") ->
        {add(scores, :small, 4) |> add(:micro, 2),
         [{"mx", "Zoho", :small} | evidence]}

      String.contains?(mx, "secureserver.net") or String.contains?(mx, "godaddy") ->
        {add(scores, :micro, 6) |> add(:small, 2),
         [{"mx", "GoDaddy", :micro} | evidence]}

      String.contains?(mx, "registrar-servers") ->
        {add(scores, :micro, 5) |> add(:small, 2),
         [{"mx", "Namecheap", :micro} | evidence]}

      String.contains?(mx, "emailsrvr.com") or String.contains?(mx, "rackspace") ->
        {add(scores, :mid_market, 4) |> add(:small, 2),
         [{"mx", "Rackspace", :mid_market} | evidence]}

      String.contains?(mx, "fastmail") ->
        {add(scores, :small, 3) |> add(:micro, 2),
         [{"mx", "Fastmail", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 6 — SPF Include Count
  # =========================================================================

  defp signal_spf_includes(signals, scores, evidence) do
    txt = get_str(signals, :dns_txt) |> String.downcase()

    if not String.contains?(txt, "v=spf1") do
      {add(scores, :micro, 2), evidence}
    else
      count = Regex.scan(~r/include:/, txt) |> length()

      cond do
        count >= 9 ->
          {add(scores, :enterprise, 8) |> add(:large_enterprise, 4),
           [{"spf_includes", "#{count}", :enterprise} | evidence]}

        count >= 6 ->
          {add(scores, :mid_market, 5) |> add(:enterprise, 3),
           [{"spf_includes", "#{count}", :mid_market} | evidence]}

        count >= 3 ->
          {add(scores, :small, 4) |> add(:mid_market, 2),
           [{"spf_includes", "#{count}", :small} | evidence]}

        count >= 1 ->
          {add(scores, :micro, 2) |> add(:small, 2),
           [{"spf_includes", "#{count}", :micro} | evidence]}

        true ->
          {add(scores, :micro, 2), evidence}
      end
    end
  end

  # =========================================================================
  # SIGNAL 7 — DMARC Policy
  # =========================================================================

  defp signal_dmarc_policy(signals, scores, evidence) do
    txt = get_str(signals, :dns_txt) |> String.downcase()

    cond do
      not String.contains?(txt, "v=dmarc1") ->
        {add(scores, :micro, 2), evidence}

      String.contains?(txt, "p=reject") ->
        {add(scores, :mid_market, 5) |> add(:enterprise, 4) |> add(:large_enterprise, 2),
         [{"dmarc", "p=reject", :mid_market} | evidence]}

      String.contains?(txt, "p=quarantine") ->
        {add(scores, :small, 3) |> add(:mid_market, 3),
         [{"dmarc", "p=quarantine", :small} | evidence]}

      String.contains?(txt, "p=none") ->
        {add(scores, :small, 2) |> add(:micro, 1),
         [{"dmarc", "p=none", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 8 — Marketing Automation (from DNS TXT + http_tech)
  # =========================================================================

  defp signal_marketing_automation(signals, scores, evidence) do
    txt = get_str(signals, :dns_txt) |> String.downcase()
    tech = get_str(signals, :http_tech) |> String.downcase()
    combined = txt <> " " <> tech

    result = {scores, evidence}

    result = if String.contains?(combined, "mktomail") or String.contains?(combined, "marketo") do
      {s, e} = result
      {add(s, :enterprise, 12) |> add(:large_enterprise, 5) |> add(:mid_market, 3),
       [{"martech", "Marketo", :enterprise} | e]}
    else
      result
    end

    result = if String.contains?(combined, "pardot") do
      {s, e} = result
      {add(s, :enterprise, 10) |> add(:mid_market, 4),
       [{"martech", "Pardot", :enterprise} | e]}
    else
      result
    end

    result = if String.contains?(combined, "eloqua") do
      {s, e} = result
      {add(s, :large_enterprise, 12) |> add(:enterprise, 6),
       [{"martech", "Eloqua", :large_enterprise} | e]}
    else
      result
    end

    result = if String.contains?(tech, "hubspot") do
      {s, e} = result
      {add(s, :small, 5) |> add(:mid_market, 4),
       [{"martech", "HubSpot", :small} | e]}
    else
      result
    end

    result = if String.contains?(combined, "mcsv.net") or String.contains?(tech, "mailchimp") do
      {s, e} = result
      {add(s, :micro, 4) |> add(:small, 3),
       [{"martech", "Mailchimp", :micro} | e]}
    else
      result
    end

    result = if String.contains?(txt, "salesforce") or String.contains?(tech, "salesforce") do
      {s, e} = result
      {add(s, :mid_market, 5) |> add(:enterprise, 4),
       [{"crm", "Salesforce", :mid_market} | e]}
    else
      result
    end

    result
  end

  # =========================================================================
  # SIGNAL 9 — Subdomain Count (CT logs)
  # =========================================================================

  defp signal_subdomain_count(signals, scores, evidence) do
    count = get_int(signals, :ctl_subdomain_count)

    cond do
      is_nil(count) -> {scores, evidence}

      count >= 500 ->
        {add(scores, :large_enterprise, 10) |> add(:enterprise, 5),
         [{"subdomains", "#{count}", :large_enterprise} | evidence]}

      count >= 100 ->
        {add(scores, :enterprise, 8) |> add(:mid_market, 3),
         [{"subdomains", "#{count}", :enterprise} | evidence]}

      count >= 20 ->
        {add(scores, :mid_market, 5) |> add(:small, 2),
         [{"subdomains", "#{count}", :mid_market} | evidence]}

      count >= 5 ->
        {add(scores, :small, 3) |> add(:micro, 1),
         [{"subdomains", "#{count}", :small} | evidence]}

      true ->
        {add(scores, :micro, 2), evidence}
    end
  end

  # =========================================================================
  # SIGNAL 10 — Tech Count
  # =========================================================================

  defp signal_tech_count(signals, scores, evidence) do
    tech = get_str(signals, :http_tech)
    count = tech |> String.split("|", trim: true) |> length()

    cond do
      count == 0 -> {scores, evidence}

      count >= 25 ->
        {add(scores, :enterprise, 8) |> add(:mid_market, 4),
         [{"tech_count", "#{count}", :enterprise} | evidence]}

      count >= 15 ->
        {add(scores, :mid_market, 5) |> add(:enterprise, 2) |> add(:small, 1),
         [{"tech_count", "#{count}", :mid_market} | evidence]}

      count >= 8 ->
        {add(scores, :small, 4) |> add(:mid_market, 2),
         [{"tech_count", "#{count}", :small} | evidence]}

      count >= 3 ->
        {add(scores, :small, 2) |> add(:micro, 2),
         [{"tech_count", "#{count}", :small} | evidence]}

      true ->
        {add(scores, :micro, 3),
         [{"tech_count", "#{count}", :micro} | evidence]}
    end
  end

  # =========================================================================
  # SIGNAL 11 — App Count (Shopify apps / WP plugins)
  # =========================================================================

  defp signal_app_count(signals, scores, evidence) do
    apps = get_str(signals, :http_apps)
    count = apps |> String.split("|", trim: true) |> length()

    cond do
      count == 0 -> {scores, evidence}

      count >= 10 ->
        {add(scores, :mid_market, 4) |> add(:small, 2),
         [{"app_count", "#{count}", :mid_market} | evidence]}

      count >= 5 ->
        {add(scores, :small, 3) |> add(:mid_market, 1),
         [{"app_count", "#{count}", :small} | evidence]}

      count >= 2 ->
        {add(scores, :small, 2) |> add(:micro, 1),
         [{"app_count", "#{count}", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 12 — CDN Tier
  # =========================================================================

  defp signal_cdn_tier(signals, scores, evidence) do
    tech = get_str(signals, :http_tech) |> String.downcase()

    cond do
      String.contains?(tech, "akamai") ->
        {add(scores, :enterprise, 8) |> add(:large_enterprise, 4),
         [{"cdn", "Akamai", :enterprise} | evidence]}

      String.contains?(tech, "fastly") ->
        {add(scores, :mid_market, 4) |> add(:enterprise, 3),
         [{"cdn", "Fastly", :mid_market} | evidence]}

      String.contains?(tech, "cloudfront") ->
        {add(scores, :mid_market, 3) |> add(:small, 2),
         [{"cdn", "CloudFront", :mid_market} | evidence]}

      String.contains?(tech, "imperva") or String.contains?(tech, "incapsula") ->
        {add(scores, :enterprise, 6) |> add(:mid_market, 3),
         [{"cdn", "Imperva", :enterprise} | evidence]}

      # Cloudflare free tier too ubiquitous — neutral
      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 13 — CMS Tier
  # =========================================================================

  defp signal_cms_tier(signals, scores, evidence) do
    tech = get_str(signals, :http_tech) |> String.downcase()

    cond do
      String.contains?(tech, "sitecore") ->
        {add(scores, :enterprise, 15) |> add(:large_enterprise, 5),
         [{"cms", "Sitecore", :enterprise} | evidence]}

      String.contains?(tech, "adobe experience manager") or String.contains?(tech, "aem") ->
        {add(scores, :enterprise, 15) |> add(:large_enterprise, 5),
         [{"cms", "AEM", :enterprise} | evidence]}

      String.contains?(tech, "drupal") ->
        {add(scores, :mid_market, 4) |> add(:enterprise, 2),
         [{"cms", "Drupal", :mid_market} | evidence]}

      String.contains?(tech, "shopify") and not String.contains?(tech, "shopify plus") ->
        {add(scores, :small, 3) |> add(:micro, 2),
         [{"cms", "Shopify", :small} | evidence]}

      String.contains?(tech, "shopify plus") ->
        {add(scores, :mid_market, 6) |> add(:small, 2),
         [{"cms", "ShopifyPlus", :mid_market} | evidence]}

      String.contains?(tech, "wix") ->
        {add(scores, :micro, 8) |> add(:small, 1),
         [{"cms", "Wix", :micro} | evidence]}

      String.contains?(tech, "squarespace") ->
        {add(scores, :micro, 6) |> add(:small, 2),
         [{"cms", "Squarespace", :micro} | evidence]}

      String.contains?(tech, "webflow") ->
        {add(scores, :small, 4) |> add(:micro, 2),
         [{"cms", "Webflow", :small} | evidence]}

      # WordPress too ubiquitous — neutral
      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 14 — Enterprise Pages
  # =========================================================================

  defp signal_enterprise_pages(signals, scores, evidence) do
    pages = get_str(signals, :http_pages) |> String.downcase()

    result = {scores, evidence}

    result = if String.contains?(pages, "/enterprise") do
      {s, e} = result
      {add(s, :mid_market, 5) |> add(:enterprise, 3),
       [{"page", "/enterprise", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(pages, "/investors") or String.contains?(pages, "/ir") do
      {s, e} = result
      {add(s, :enterprise, 8) |> add(:large_enterprise, 4),
       [{"page", "/investors", :enterprise} | e]}
    else
      result
    end

    result = if String.contains?(pages, "/careers") or String.contains?(pages, "/jobs") do
      {s, e} = result
      {add(s, :mid_market, 4) |> add(:small, 2),
       [{"page", "/careers", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(pages, "/security") or String.contains?(pages, "/trust") do
      {s, e} = result
      {add(s, :mid_market, 3) |> add(:enterprise, 2),
       [{"page", "/security", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(pages, "/partners") or String.contains?(pages, "/partner-program") do
      {s, e} = result
      {add(s, :mid_market, 3) |> add(:enterprise, 2),
       [{"page", "/partners", :mid_market} | e]}
    else
      result
    end

    result
  end

  # =========================================================================
  # SIGNAL 15 — Domain Age
  # =========================================================================

  defp signal_domain_age(signals, scores, evidence) do
    created = get_str(signals, :rdap_domain_created_at)

    case parse_year(created) do
      nil -> {scores, evidence}
      year ->
        age = Date.utc_today().year - year

        cond do
          age >= 25 ->
            {add(scores, :enterprise, 5) |> add(:large_enterprise, 3),
             [{"domain_age", "#{age}yr", :enterprise} | evidence]}

          age >= 15 ->
            {add(scores, :mid_market, 3) |> add(:enterprise, 2),
             [{"domain_age", "#{age}yr", :mid_market} | evidence]}

          age >= 5 ->
            {add(scores, :small, 2),
             [{"domain_age", "#{age}yr", :small} | evidence]}

          age < 2 ->
            {add(scores, :micro, 3) |> add(:small, 1),
             [{"domain_age", "#{age}yr", :micro} | evidence]}

          true -> {scores, evidence}
        end
    end
  end

  # =========================================================================
  # SIGNAL 16 — Hosting Tier (BGP ASN)
  # =========================================================================

  defp signal_hosting_tier(signals, scores, evidence) do
    asn_org = get_str(signals, :bgp_asn_org) |> String.downcase()
    asn_number = get_str(signals, :bgp_asn_number)

    cond do
      asn_org == "" -> {scores, evidence}

      # Shared hosting — strong micro signal
      String.contains?(asn_org, "godaddy") or String.contains?(asn_org, "bluehost") or
      String.contains?(asn_org, "hostgator") or String.contains?(asn_org, "hostinger") or
      String.contains?(asn_org, "namecheap") or String.contains?(asn_org, "dreamhost") ->
        {add(scores, :micro, 6) |> add(:small, 2),
         [{"hosting", "shared:#{short_asn(asn_org)}", :micro} | evidence]}

      # Own ASN (not a hosting/cloud provider) = likely enterprise
      not hosting_provider?(asn_org) and asn_number != "" ->
        {add(scores, :enterprise, 6) |> add(:large_enterprise, 3),
         [{"hosting", "own_asn:#{short_asn(asn_org)}", :enterprise} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 17 — Email Security / Compliance tools (DNS TXT verification)
  # =========================================================================

  defp signal_email_security(signals, scores, evidence) do
    txt = get_str(signals, :dns_txt) |> String.downcase()

    result = {scores, evidence}

    result = if String.contains?(txt, "onetrust") or String.contains?(txt, "trustarc") do
      {s, e} = result
      {add(s, :enterprise, 5) |> add(:mid_market, 3),
       [{"compliance", "OneTrust/TrustArc", :enterprise} | e]}
    else
      result
    end

    result = if String.contains?(txt, "atlassian") do
      {s, e} = result
      {add(s, :mid_market, 3) |> add(:small, 2),
       [{"tools", "Atlassian", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(txt, "docusign") do
      {s, e} = result
      {add(s, :mid_market, 3) |> add(:enterprise, 2),
       [{"tools", "DocuSign", :mid_market} | e]}
    else
      result
    end

    result
  end

  # =========================================================================
  # SIGNAL 18 — Enterprise Tool Detection (from http_tech)
  # =========================================================================

  defp signal_enterprise_tools(signals, scores, evidence) do
    tech = get_str(signals, :http_tech) |> String.downcase()

    result = {scores, evidence}

    result = if String.contains?(tech, "adobe analytics") do
      {s, e} = result
      {add(s, :enterprise, 10) |> add(:large_enterprise, 4),
       [{"tool", "AdobeAnalytics", :enterprise} | e]}
    else
      result
    end

    result = if String.contains?(tech, "segment") do
      {s, e} = result
      {add(s, :mid_market, 3) |> add(:small, 2),
       [{"tool", "Segment", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(tech, "intercom") do
      {s, e} = result
      {add(s, :small, 4) |> add(:mid_market, 3),
       [{"tool", "Intercom", :small} | e]}
    else
      result
    end

    result = if String.contains?(tech, "zendesk") do
      {s, e} = result
      {add(s, :mid_market, 4) |> add(:small, 2),
       [{"tool", "Zendesk", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(tech, "amplitude") or String.contains?(tech, "mixpanel") do
      {s, e} = result
      {add(s, :small, 3) |> add(:mid_market, 3),
       [{"tool", "ProductAnalytics", :small} | e]}
    else
      result
    end

    result = if String.contains?(tech, "posthog") or String.contains?(tech, "plausible") do
      {s, e} = result
      {add(s, :small, 3) |> add(:micro, 2),
       [{"tool", "PrivacyAnalytics", :small} | e]}
    else
      result
    end

    result = if String.contains?(tech, "drift") do
      {s, e} = result
      {add(s, :mid_market, 4) |> add(:enterprise, 3),
       [{"tool", "Drift", :mid_market} | e]}
    else
      result
    end

    result
  end

  # =========================================================================
  # SIGNAL 19 — Subdomain Names (engineering maturity from CT logs)
  # dev/staging/api/docs/app patterns reveal engineering team size
  # =========================================================================

  @enterprise_subdomains ~w(api staging dev app docs blog status support help
    admin portal dashboard cdn assets mail webmail vpn sso auth login
    jira confluence wiki gitlab jenkins ci cd monitor grafana sentry)

  defp signal_subdomain_names(signals, scores, evidence) do
    subs = get_str(signals, :ctl_subdomains) |> String.downcase() |> String.split("|", trim: true)

    if subs == [] do
      {scores, evidence}
    else
      infra_count = Enum.count(subs, fn sub ->
        Enum.any?(@enterprise_subdomains, &(sub == &1 or String.starts_with?(sub, &1 <> "-")))
      end)

      has_env = Enum.any?(subs, &(&1 in ~w(staging dev stg uat prod preprod)))
      has_api = Enum.any?(subs, &(&1 in ~w(api api-v2 graphql grpc)))
      has_docs = Enum.any?(subs, &(&1 in ~w(docs developer developers)))

      cond do
        infra_count >= 8 ->
          {add(scores, :enterprise, 8) |> add(:large_enterprise, 4),
           [{"subnames", "#{infra_count}_infra", :enterprise} | evidence]}

        infra_count >= 4 ->
          {add(scores, :mid_market, 5) |> add(:enterprise, 3),
           [{"subnames", "#{infra_count}_infra", :mid_market} | evidence]}

        has_env and has_api ->
          {add(scores, :mid_market, 4) |> add(:small, 2),
           [{"subnames", "env+api", :mid_market} | evidence]}

        has_env or has_api or has_docs ->
          {add(scores, :small, 3) |> add(:mid_market, 2),
           [{"subnames", "dev_env", :small} | evidence]}

        true -> {scores, evidence}
      end
    end
  end

  # =========================================================================
  # SIGNAL 20 — Nameservers (enterprise DNS providers)
  # =========================================================================

  defp signal_nameservers(signals, scores, evidence) do
    ns = get_str(signals, :rdap_nameservers) |> String.downcase()

    cond do
      ns == "" -> {scores, evidence}

      String.contains?(ns, "ultradns") ->
        {add(scores, :enterprise, 6) |> add(:large_enterprise, 3),
         [{"ns", "UltraDNS", :enterprise} | evidence]}

      String.contains?(ns, "dynect") or String.contains?(ns, "dyn.com") ->
        {add(scores, :enterprise, 5) |> add(:mid_market, 3),
         [{"ns", "Dyn", :enterprise} | evidence]}

      String.contains?(ns, "nsone") or String.contains?(ns, "ns1.") ->
        {add(scores, :mid_market, 4) |> add(:enterprise, 3),
         [{"ns", "NS1", :mid_market} | evidence]}

      String.contains?(ns, "awsdns") ->
        {add(scores, :small, 3) |> add(:mid_market, 2),
         [{"ns", "Route53", :small} | evidence]}

      String.contains?(ns, "cloudflare") ->
        # Too ubiquitous for strong signal, but slight small+ lean
        {add(scores, :small, 2) |> add(:mid_market, 1),
         [{"ns", "Cloudflare", :small} | evidence]}

      String.contains?(ns, "domaincontrol") or String.contains?(ns, "registrar-servers") ->
        {add(scores, :micro, 4) |> add(:small, 1),
         [{"ns", "registrar_default", :micro} | evidence]}

      String.contains?(ns, "googledomains") or String.contains?(ns, "google") ->
        {add(scores, :small, 2) |> add(:micro, 1),
         [{"ns", "Google", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 21 — DNS Load Balancing (multiple A records = infrastructure)
  # =========================================================================

  defp signal_dns_load_balancing(signals, scores, evidence) do
    a_records = get_str(signals, :dns_a) |> String.split("|", trim: true) |> length()
    aaaa_records = get_str(signals, :dns_aaaa) |> String.split("|", trim: true) |> length()
    total = a_records + aaaa_records

    cond do
      total >= 8 ->
        {add(scores, :enterprise, 5) |> add(:large_enterprise, 2),
         [{"dns_lb", "#{total}_records", :enterprise} | evidence]}

      total >= 4 ->
        {add(scores, :mid_market, 3) |> add(:small, 1),
         [{"dns_lb", "#{total}_records", :mid_market} | evidence]}

      total == 0 ->
        {add(scores, :micro, 2), evidence}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 22 — Structured Data / OpenGraph (marketing sophistication)
  # =========================================================================

  defp signal_structured_data(signals, scores, evidence) do
    schema = get_str(signals, :http_schema_type) |> String.downcase()
    og = get_str(signals, :http_og_type)

    result = {scores, evidence}

    result = if schema != "" do
      {s, e} = result
      cond do
        String.contains?(schema, "organization") ->
          {add(s, :mid_market, 3) |> add(:enterprise, 2),
           [{"schema", "Organization", :mid_market} | e]}

        String.contains?(schema, "product") ->
          {add(s, :small, 2) |> add(:mid_market, 1),
           [{"schema", "Product", :small} | e]}

        true ->
          {add(s, :small, 1), [{"schema", schema, :small} | e]}
      end
    else
      result
    end

    result = if og != "" do
      {s, e} = result
      {add(s, :small, 1), e}
    else
      result
    end

    result
  end

  # =========================================================================
  # SIGNAL 23 — Title Keywords (enterprise language in page title)
  # =========================================================================

  defp signal_title_keywords(signals, scores, evidence) do
    title = get_str(signals, :http_title) |> String.downcase()
    desc = get_str(signals, :http_meta_description) |> String.downcase()
    combined = title <> " " <> desc

    result = {scores, evidence}

    result = if String.contains?(combined, "enterprise") or String.contains?(combined, "fortune 500") do
      {s, e} = result
      {add(s, :enterprise, 4) |> add(:mid_market, 2),
       [{"title", "enterprise_lang", :enterprise} | e]}
    else
      result
    end

    result = if String.contains?(combined, "platform") and
               (String.contains?(combined, "leading") or String.contains?(combined, "global")) do
      {s, e} = result
      {add(s, :mid_market, 3) |> add(:enterprise, 2),
       [{"title", "platform_leader", :mid_market} | e]}
    else
      result
    end

    result = if String.contains?(combined, "free website") or String.contains?(combined, "my blog") or
                String.contains?(combined, "personal site") do
      {s, e} = result
      {add(s, :micro, 4) |> add(:small, 1),
       [{"title", "personal", :micro} | e]}
    else
      result
    end

    result
  end

  # =========================================================================
  # SIGNAL 24 — Contact Emails (more emails = larger org)
  # =========================================================================

  defp signal_contact_emails(signals, scores, evidence) do
    emails = get_str(signals, :http_emails) |> String.split("|", trim: true)
    count = length(emails)

    cond do
      count == 0 -> {scores, evidence}

      count >= 5 ->
        {add(scores, :mid_market, 4) |> add(:enterprise, 2),
         [{"emails", "#{count}", :mid_market} | evidence]}

      count >= 3 ->
        {add(scores, :small, 3) |> add(:mid_market, 1),
         [{"emails", "#{count}", :small} | evidence]}

      true -> {scores, evidence}
    end
  end

  # =========================================================================
  # SIGNAL 25 — Industry Prior (some industries skew larger)
  # =========================================================================

  defp signal_industry_prior(signals, scores, evidence) do
    industry = get_str(signals, :industry)

    case industry do
      "Finance" ->
        {add(scores, :mid_market, 3) |> add(:enterprise, 2),
         [{"industry", "Finance", :mid_market} | evidence]}

      "Healthcare" ->
        {add(scores, :mid_market, 3) |> add(:enterprise, 2),
         [{"industry", "Healthcare", :mid_market} | evidence]}

      "Government" ->
        {add(scores, :mid_market, 3) |> add(:enterprise, 2),
         [{"industry", "Government", :mid_market} | evidence]}

      "Education" ->
        {add(scores, :mid_market, 2) |> add(:small, 2),
         [{"industry", "Education", :mid_market} | evidence]}

      "Real Estate" ->
        {add(scores, :small, 2) |> add(:mid_market, 2),
         [{"industry", "RealEstate", :small} | evidence]}

      _ -> {scores, evidence}
    end
  end

  # =========================================================================
  # RESULT COMPUTATION
  # =========================================================================

  defp pick_result(scores, evidence, signals) do
    total = scores |> Map.values() |> Enum.sum()

    if total == 0 or length(evidence) < @min_evidence_count do
      @empty_result
    else
      probs = softmax(scores)
      {winner, max_prob} = Enum.max_by(probs, fn {_k, v} -> v end)
      evidence_density = min(length(evidence) / 10.0, 1.0)
      confidence = Float.round(max_prob * 0.7 + evidence_density * 0.3, 2) |> min(0.99)

      if confidence >= @min_confidence do
        employee_bracket = estimate_employees(winner, signals)

        evidence_str = evidence
        |> Enum.reverse()
        |> Enum.map(fn {signal, value, bracket} ->
          "#{signal}:#{value}→#{bracket}"
        end)
        |> Enum.join("|")

        %{
          estimated_revenue: Map.get(@bracket_labels, winner, ""),
          estimated_employees: Map.get(@employee_labels, employee_bracket, Map.get(@employee_labels, winner, "")),
          revenue_confidence: confidence,
          revenue_evidence: evidence_str
        }
      else
        @empty_result
      end
    end
  end

  defp softmax(scores) do
    temperature = 2.0
    values = Enum.map(@brackets, fn b -> Map.get(scores, b, 0) / temperature end)
    max_v = Enum.max(values)
    exps = Enum.map(values, fn v -> :math.exp(v - max_v) end)
    sum_exp = Enum.sum(exps)

    @brackets
    |> Enum.zip(exps)
    |> Enum.map(fn {b, e} -> {b, e / sum_exp} end)
    |> Map.new()
  end

  # =========================================================================
  # EMPLOYEE ESTIMATION
  # =========================================================================

  defp estimate_employees(revenue_bracket, signals) do
    business_model = get_str(signals, :business_model)
    rpe = Map.get(@rpe_by_industry, business_model, 120_000)

    midpoint = Map.get(@bracket_midpoints, revenue_bracket, 3_000_000)
    estimated_employees = midpoint / rpe

    cond do
      estimated_employees <= 10 -> :micro
      estimated_employees <= 50 -> :small
      estimated_employees <= 500 -> :mid_market
      estimated_employees <= 5000 -> :enterprise
      true -> :large_enterprise
    end
  end

  # =========================================================================
  # HELPERS
  # =========================================================================

  defp add(scores, bracket, points), do: Map.update!(scores, bracket, &(&1 + points))

  defp get_str(signals, key) do
    case Map.get(signals, key) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  defp get_int(signals, key) do
    case Map.get(signals, key) do
      v when is_integer(v) -> v
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> nil
        end
      _ -> nil
    end
  end

  defp parse_year(nil), do: nil
  defp parse_year(""), do: nil
  defp parse_year(str) when is_binary(str) do
    case Regex.run(~r/^(\d{4})/, str) do
      [_, year] -> String.to_integer(year)
      _ -> nil
    end
  end
  defp parse_year(%DateTime{year: y}), do: y
  defp parse_year(%NaiveDateTime{year: y}), do: y
  defp parse_year(_), do: nil

  defp short_asn(org) do
    org |> String.split(",") |> List.first() |> String.slice(0, 20) |> String.trim()
  end

  @hosting_providers ~w(
    amazon aws cloudflare google cloud digitalocean linode vultr hetzner ovh
    microsoft azure shopify squarespace wix godaddy bluehost hostgator
    hostinger dreamhost netlify vercel render railway heroku
    rackspace softlayer ibm oracle akamai fastly leaseweb
  )

  defp hosting_provider?(org) do
    Enum.any?(@hosting_providers, &String.contains?(org, &1))
  end
end
