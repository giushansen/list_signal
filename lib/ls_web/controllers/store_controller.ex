defmodule LSWeb.StoreController do
  use LSWeb, :controller
  require Logger

  plug :cache_headers

  # Column positions derived dynamically from LS.Cluster.Inserter.columns/0 (52-column schema)

  # /shopify/:slug — expects a Shopify store. If not Shopify, 301 to /website/:slug
  def show_shopify(conn, %{"slug" => slug}) do
    domain = slug_to_domain(slug)
    Logger.info("[STORE] show_shopify slug=#{slug} domain=#{domain}")

    case find_store(domain, slug) do
      {:found, row, resolved_domain} ->
        store = parse_store(row, resolved_domain)
        if is_shopify?(store) do
          render_store(conn, store)
        else
          Logger.info("[STORE] #{domain} is NOT Shopify, redirecting to /website/#{slug}")
          conn |> put_status(301) |> redirect(to: "/website/#{slug}")
        end
      :not_found ->
        Logger.info("[STORE] #{domain} not found in DB")
        render_not_found(conn, domain)
    end
  end

  # /website/:slug — expects a non-Shopify site. If Shopify, 301 to /shopify/:slug
  def show_website(conn, %{"slug" => slug}) do
    domain = slug_to_domain(slug)
    Logger.info("[STORE] show_website slug=#{slug} domain=#{domain}")

    case find_store(domain, slug) do
      {:found, row, resolved_domain} ->
        store = parse_store(row, resolved_domain)
        if is_shopify?(store) do
          Logger.info("[STORE] #{domain} IS Shopify, redirecting to /shopify/#{slug}")
          conn |> put_status(301) |> redirect(to: "/shopify/#{slug}")
        else
          render_store(conn, store)
        end
      :not_found ->
        Logger.info("[STORE] #{domain} not found in DB")
        render_not_found(conn, domain)
    end
  end

  @country_slug_to_code %{
    "united-states" => "us", "united-kingdom" => "gb", "canada" => "ca",
    "australia" => "au", "germany" => "de", "france" => "fr", "netherlands" => "nl",
    "sweden" => "se", "japan" => "jp", "south-korea" => "kr", "india" => "in",
    "brazil" => "br", "new-zealand" => "nz", "ireland" => "ie", "singapore" => "sg",
    "italy" => "it", "spain" => "es", "denmark" => "dk", "norway" => "no",
    "finland" => "fi", "belgium" => "be", "switzerland" => "ch", "austria" => "at",
    "poland" => "pl", "portugal" => "pt", "mexico" => "mx", "israel" => "il",
    "hong-kong" => "hk", "taiwan" => "tw", "uae" => "ae", "south-africa" => "za",
    "china" => "cn", "russia" => "ru", "turkey" => "tr", "czech-republic" => "cz",
    "hungary" => "hu", "romania" => "ro", "greece" => "gr", "ukraine" => "ua",
    "thailand" => "th", "vietnam" => "vn", "indonesia" => "id", "malaysia" => "my",
    "argentina" => "ar", "colombia" => "co", "chile" => "cl", "peru" => "pe",
    "philippines" => "ph", "nigeria" => "ng", "egypt" => "eg", "kenya" => "ke",
    "saudi-arabia" => "sa", "pakistan" => "pk", "bangladesh" => "bd"
  }

  # /store/:slug — legacy route, redirects to /shopify/ or /website/ based on data
  # Also handles country-name slugs like /store/united-states → /top/shopify-stores-us
  def show(conn, %{"slug" => slug}) do
    # Check if slug is a country name first
    case Map.get(@country_slug_to_code, slug) do
      nil ->
        domain = slug_to_domain(slug)
        Logger.info("[STORE] show (legacy) slug=#{slug} domain=#{domain}")

        case find_store(domain, slug) do
          {:found, row, resolved_domain} ->
            store = parse_store(row, resolved_domain)
            if is_shopify?(store) do
              conn |> put_status(301) |> redirect(to: "/shopify/#{slug}")
            else
              conn |> put_status(301) |> redirect(to: "/website/#{slug}")
            end
          :not_found ->
            render_not_found(conn, domain)
        end

      code ->
        conn |> put_status(301) |> redirect(to: "/top/shopify-stores-#{code}")
    end
  end

  defp is_shopify?(store), do: Enum.any?(store.tech, &(String.downcase(&1) |> String.contains?("shopify")))

  # ── Finding store data ──

  defp find_store(domain, slug) do
    Logger.debug("[STORE] find_store domain=#{domain} slug=#{slug}")

    # 1. ClickHouse
    case LS.Clickhouse.get_store(domain) do
      {:ok, [row | _]} ->
        Logger.debug("[STORE] #{domain} found in ClickHouse")
        {:found, row, domain}
      _ ->
        # 2. ETS cache
        case LS.Tools.Lookup.get_cached_row(domain) do
          row when is_list(row) ->
            Logger.debug("[STORE] #{domain} found in ETS cache")
            {:found, row, domain}
          _ ->
            # 3. Try simple alternative domain (just the basic slug → domain)
            Logger.debug("[STORE] #{domain} not in CH/ETS, trying alternatives for slug=#{slug}")
            try_alternatives(slug, domain)
        end
    end
  end

  defp try_alternatives(slug, primary_domain) do
    parts = String.split(slug, "-")
    # Only try the most likely alternative: www.domain.tld
    alternatives = if length(parts) >= 3 and hd(parts) == "www" do
      www_domain = best_guess_www(parts)
      if www_domain != primary_domain, do: [www_domain], else: []
    else
      []
    end

    Enum.find_value(alternatives, :not_found, fn alt ->
      Logger.debug("[STORE] Trying alternative: #{alt}")
      case LS.Clickhouse.get_store(alt) do
        {:ok, [row | _]} -> {:found, row, alt}
        _ ->
          case LS.Tools.Lookup.get_cached_row(alt) do
            row when is_list(row) -> {:found, row, alt}
            _ -> nil
          end
      end
    end)
  end

  defp best_guess_www(parts) do
    tld_parts = Enum.slice(parts, -2, 2)
    tld_candidate = Enum.join(tld_parts, ".")
    if two_part_tld?(tld_candidate) do
      base = parts |> Enum.slice(1, length(parts) - 3) |> Enum.join("-")
      "www.#{base}.#{tld_candidate}"
    else
      base = parts |> Enum.slice(1, length(parts) - 2) |> Enum.join("-")
      "www.#{base}.#{List.last(parts)}"
    end
  end

  # ── Rendering ──

  defp render_store(conn, store) do
    Logger.info("[STORE] Rendering #{store.domain} — tech:#{length(store.tech)} bgp:#{store.bgp_asn_org} rdap:#{store.rdap_registrar} tranco:#{inspect(store.tranco_rank)} country:#{store.country}")
    conn
    |> assign(:page_title, "#{store.title} — Tech Stack & Analysis")
    |> assign(:page_description, "#{store.title} uses #{store.tech_summary}. See full tech stack.")
    |> assign(:store, store)
    |> assign(:json_ld, store_json_ld(store))
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:show)
  end

  defp render_not_found(conn, domain) do
    conn
    |> put_status(404)
    |> assign(:page_title, "#{domain} — Not Found")
    |> assign(:domain, domain)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:not_found)
  end

  # ── Parsing ──

  defp parse_store(row, domain) do
    # Dynamic column lookup — always in sync with inserter schema
    col_idx = LS.Cluster.Inserter.columns() |> Enum.with_index() |> Map.new()
    at = fn key -> Enum.at(row, Map.get(col_idx, key, -1)) end
    s = fn key -> at.(key) || "" end

    tech = parse_pipe(at.(:http_tech))
    tld = s.(:ctl_tld)
    language = s.(:http_language)
    bgp_country = s.(:bgp_asn_country)
    country = LS.CountryInferrer.infer(tld, language, nil, bgp_country)
    mx_records = parse_pipe(at.(:dns_mx))
    dns_txt = parse_pipe(at.(:dns_txt))
    dns_txt_joined = Enum.join(dns_txt, " ")
    nameservers = parse_pipe(at.(:rdap_nameservers))
    created_at = at.(:rdap_domain_created_at)
    emails = parse_pipe(at.(:http_emails))
    tld = domain |> String.split(".") |> List.last() |> String.upcase()
    %{
      domain: domain,
      title: decode_html(at.(:http_title)) || domain,
      tech: tech,
      tech_summary: tech |> Enum.take(5) |> Enum.join(", "),
      http_status: at.(:http_status),
      http_response_time: at.(:http_response_time),
      http_language: s.(:http_language),
      http_meta_description: s.(:http_meta_description),
      http_content_type: s.(:http_content_type),
      http_apps: parse_pipe(at.(:http_apps)),
      http_pages: parse_pipe(at.(:http_pages)),
      http_error: s.(:http_error),
      dns_a: parse_pipe(at.(:dns_a)),
      dns_aaaa: parse_pipe(at.(:dns_aaaa)),
      dns_mx: mx_records,
      dns_txt: dns_txt,
      dns_cname: parse_pipe(at.(:dns_cname)),
      emails: emails,
      bgp_ip: s.(:bgp_ip),
      bgp_asn_number: s.(:bgp_asn_number),
      bgp_asn_org: s.(:bgp_asn_org),
      bgp_asn_country: country,
      bgp_asn_prefix: s.(:bgp_asn_prefix),
      country: country,
      country_flag: country_to_flag(country),
      ctl_tld: s.(:ctl_tld),
      ctl_issuer: s.(:ctl_issuer),
      ctl_subdomain_count: at.(:ctl_subdomain_count),
      ctl_subdomains: parse_pipe(at.(:ctl_subdomains)),
      rdap_domain_created_at: created_at,
      rdap_domain_expires_at: at.(:rdap_domain_expires_at),
      rdap_domain_updated_at: at.(:rdap_domain_updated_at),
      rdap_registrar: s.(:rdap_registrar),
      rdap_registrar_iana_id: s.(:rdap_registrar_iana_id),
      rdap_nameservers: nameservers,
      rdap_status: s.(:rdap_status),
      tranco_rank: at.(:tranco_rank),
      majestic_rank: at.(:majestic_rank),
      majestic_ref_subnets: at.(:majestic_ref_subnets),
      is_malware: s.(:is_malware),
      is_phishing: s.(:is_phishing),
      is_disposable_email: s.(:is_disposable_email),
      business_model: s.(:business_model),
      industry: s.(:industry),
      estimated_revenue: s.(:estimated_revenue),
      estimated_employees: s.(:estimated_employees),
      revenue_confidence: at.(:revenue_confidence),
      revenue_evidence: s.(:revenue_evidence),
      tld: tld,
      domain_age: compute_domain_age(created_at),
      mail_provider: extract_mail_provider(mx_records),
      dns_provider: extract_dns_provider(nameservers),
      has_spf: String.contains?(dns_txt_joined, "v=spf1"),
      has_dmarc: String.contains?(dns_txt_joined, "v=DMARC"),
      email_count: length(emails),
      subdomain_count: at.(:ctl_subdomain_count) || 0,
      language_flag: language_to_flag(s.(:http_language)),
      enriched_at: s.(:enriched_at),
      worker: s.(:worker)
    }
  end

  # ── Helpers ──

  defp parse_pipe(""), do: []
  defp parse_pipe(nil), do: []
  defp parse_pipe(s) when is_binary(s), do: s |> String.split("|") |> Enum.reject(&(&1 == ""))
  defp parse_pipe(_), do: []

  defp decode_html(nil), do: nil
  defp decode_html(s) when is_binary(s) do
    s
    |> String.replace("&amp;", "&") |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">") |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'") |> String.replace("&apos;", "'")
    |> String.replace("&nbsp;", " ") |> String.replace("&ndash;", "\u2013")
    |> String.replace("&mdash;", "\u2014") |> String.replace("&trade;", "\u2122")
    |> String.replace("&reg;", "\u00AE") |> String.replace("&copy;", "\u00A9")
    |> decode_numeric_entities()
  end

  defp decode_numeric_entities(s) do
    Regex.replace(~r/&#(\d+);/, s, fn _, code ->
      try do <<String.to_integer(code)::utf8>> catch _, _ -> "" end
    end)
  end

  defp country_to_flag(""), do: ""
  defp country_to_flag(code) when byte_size(code) == 2 do
    code |> String.upcase() |> String.to_charlist()
    |> Enum.map(&(&1 + 0x1F1A5)) |> List.to_string()
  rescue _ -> ""
  end
  defp country_to_flag(_), do: ""

  defp compute_domain_age(nil), do: nil
  defp compute_domain_age(created_at) when is_binary(created_at) do
    case Date.from_iso8601(String.slice(created_at, 0, 10)) do
      {:ok, date} ->
        days = Date.diff(Date.utc_today(), date)
        cond do
          days < 30 -> "#{days} days"
          days < 365 -> "#{div(days, 30)} months"
          true ->
            years = div(days, 365)
            months = div(rem(days, 365), 30)
            if months > 0, do: "#{years}y #{months}m", else: "#{years} years"
        end
      _ -> nil
    end
  end
  defp compute_domain_age(_), do: nil

  @mail_providers %{
    "google" => "Google Workspace", "googlemail" => "Google Workspace",
    "outlook" => "Microsoft 365", "microsoft" => "Microsoft 365",
    "zoho" => "Zoho Mail", "protonmail" => "ProtonMail", "proton" => "ProtonMail",
    "icloud" => "Apple iCloud", "apple" => "Apple iCloud",
    "yandex" => "Yandex Mail", "mail.ru" => "Mail.ru",
    "fastmail" => "Fastmail", "migadu" => "Migadu",
    "forwardemail" => "Forward Email", "improvmx" => "ImprovMX",
    "mimecast" => "Mimecast", "barracuda" => "Barracuda",
    "messagelabs" => "Broadcom/Symantec", "pphosted" => "Proofpoint",
    "emailsrvr" => "Rackspace", "secureserver" => "GoDaddy",
    "registrar-servers" => "Namecheap", "titan" => "Titan Email",
    "hey" => "HEY (Basecamp)", "mailgun" => "Mailgun", "sendgrid" => "SendGrid",
    "shopify" => "Shopify Mail"
  }

  defp extract_mail_provider([]), do: nil
  defp extract_mail_provider(mx_records) do
    primary = mx_records |> List.first("") |> String.downcase()
    Enum.find_value(@mail_providers, fn {pattern, name} ->
      if String.contains?(primary, pattern), do: name
    end)
  end

  @dns_providers %{
    "cloudflare" => "Cloudflare", "awsdns" => "Amazon Route 53",
    "google" => "Google Cloud DNS", "dynect" => "Oracle Dyn",
    "domaincontrol" => "GoDaddy", "registrar-servers" => "Namecheap",
    "nsone" => "NS1", "ultradns" => "UltraDNS",
    "digitalocean" => "DigitalOcean", "vultr" => "Vultr"
  }

  defp extract_dns_provider([]), do: nil
  defp extract_dns_provider(nameservers) when is_list(nameservers) do
    primary = nameservers |> List.first("") |> String.downcase()
    Enum.find_value(@dns_providers, fn {pattern, name} ->
      if String.contains?(primary, pattern), do: name
    end) || if primary != "", do: primary |> String.split(".") |> Enum.take(-2) |> Enum.join(".")
  end
  defp extract_dns_provider(_), do: nil

  @lang_flags %{
    "en" => "\u{1F1EC}\u{1F1E7}", "fr" => "\u{1F1EB}\u{1F1F7}", "de" => "\u{1F1E9}\u{1F1EA}",
    "es" => "\u{1F1EA}\u{1F1F8}", "pt" => "\u{1F1E7}\u{1F1F7}", "it" => "\u{1F1EE}\u{1F1F9}",
    "nl" => "\u{1F1F3}\u{1F1F1}", "ja" => "\u{1F1EF}\u{1F1F5}", "ko" => "\u{1F1F0}\u{1F1F7}",
    "zh" => "\u{1F1E8}\u{1F1F3}", "ru" => "\u{1F1F7}\u{1F1FA}", "ar" => "\u{1F1F8}\u{1F1E6}",
    "hi" => "\u{1F1EE}\u{1F1F3}", "tr" => "\u{1F1F9}\u{1F1F7}", "pl" => "\u{1F1F5}\u{1F1F1}",
    "sv" => "\u{1F1F8}\u{1F1EA}", "da" => "\u{1F1E9}\u{1F1F0}", "no" => "\u{1F1F3}\u{1F1F4}",
    "fi" => "\u{1F1EB}\u{1F1EE}", "cs" => "\u{1F1E8}\u{1F1FF}", "th" => "\u{1F1F9}\u{1F1ED}",
    "vi" => "\u{1F1FB}\u{1F1F3}", "id" => "\u{1F1EE}\u{1F1E9}", "ms" => "\u{1F1F2}\u{1F1FE}",
    "uk" => "\u{1F1FA}\u{1F1E6}", "ro" => "\u{1F1F7}\u{1F1F4}", "el" => "\u{1F1EC}\u{1F1F7}",
    "he" => "\u{1F1EE}\u{1F1F1}", "hu" => "\u{1F1ED}\u{1F1FA}", "bg" => "\u{1F1E7}\u{1F1EC}"
  }

  defp language_to_flag(""), do: ""
  defp language_to_flag(lang) do
    code = lang |> String.downcase() |> String.slice(0, 2)
    Map.get(@lang_flags, code, "")
  end

  defp slug_to_domain(slug) do
    parts = String.split(slug, "-")
    rejoin_domain(parts)
  end

  defp rejoin_domain(parts) when length(parts) >= 3 do
    last2 = Enum.slice(parts, -2, 2) |> Enum.join(".")
    if two_part_tld?(last2) do
      base = Enum.slice(parts, 0, length(parts) - 2) |> Enum.join("-")
      "#{base}.#{last2}"
    else
      base = Enum.slice(parts, 0, length(parts) - 1) |> Enum.join("-")
      "#{base}.#{List.last(parts)}"
    end
  end
  defp rejoin_domain(parts), do: Enum.join(parts, ".")

  @two_part_tlds ~w(com.sg co.uk com.au co.nz com.br com.hk co.jp co.kr com.my
                     com.ph co.th co.za com.tw com.mx co.in co.il com.sa com.ar
                     com.co com.ng com.pk co.ke com.ua)
  defp two_part_tld?(tld), do: tld in @two_part_tlds

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=300, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end

  defp store_json_ld(store) do
    %{
      "@context" => "https://schema.org", "@type" => "Organization",
      "name" => store.title, "url" => "https://#{store.domain}",
      "address" => %{"@type" => "PostalAddress", "addressCountry" => store.country}
    }
    |> maybe_put("description", store.http_meta_description)
    |> maybe_put("foundingDate", date_slice(store.rdap_domain_created_at))
    |> maybe_put("email", List.first(store.emails || []))
    |> Jason.encode!()
  end

  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp date_slice(nil), do: nil
  defp date_slice(s) when is_binary(s), do: String.slice(s, 0, 10)
  defp date_slice(_), do: nil
end
