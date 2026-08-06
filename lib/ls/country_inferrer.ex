defmodule LS.CountryInferrer do
  @moduledoc """
  Infers the likely business country from TLD, language, RDAP, and BGP signals.

  Priority order:
    1. Country-code TLD (real ccTLDs only, excludes tech/vanity like .io, .ai, .co)
    2. HTTP language → most likely country
    3. RDAP registrant country (when available)
    4. English default → US (statistically most common)
    5. BGP ASN country (fallback, unreliable for CDN-hosted sites)
  """

  # ── Real country-code TLDs (single-part) ──
  # Excludes vanity/tech TLDs: .io, .ai, .to, .tv, .co, .me, .cc, .ws, .tk, .gg, .ly, .fm, .la
  @cctld_to_country %{
    "fr" => "FR", "de" => "DE", "jp" => "JP", "ca" => "CA", "uk" => "GB",
    "it" => "IT", "es" => "ES", "nl" => "NL", "se" => "SE", "no" => "NO",
    "dk" => "DK", "fi" => "FI", "be" => "BE", "ch" => "CH", "at" => "AT",
    "pl" => "PL", "pt" => "PT", "br" => "BR", "mx" => "MX", "il" => "IL",
    "in" => "IN", "sg" => "SG", "ae" => "AE", "za" => "ZA", "nz" => "NZ",
    "au" => "AU", "ie" => "IE", "kr" => "KR", "tw" => "TW", "hk" => "HK",
    "ru" => "RU", "tr" => "TR", "cz" => "CZ", "hu" => "HU", "ro" => "RO",
    "bg" => "BG", "gr" => "GR", "ua" => "UA", "th" => "TH", "vn" => "VN",
    "id" => "ID", "my" => "MY", "ar" => "AR", "pe" => "PE", "ve" => "VE",
    "eg" => "EG", "ng" => "NG", "gh" => "GH", "sa" => "SA", "pk" => "PK",
    "ke" => "KE", "tz" => "TZ", "zw" => "ZW", "ph" => "PH", "cl" => "CL",
    "uy" => "UY", "ec" => "EC", "cr" => "CR", "pa" => "PA",
    "gt" => "GT", "hn" => "HN", "py" => "PY", "bo" => "BO",
    "cn" => "CN", "hr" => "HR", "si" => "SI", "sk" => "SK", "rs" => "RS",
    "ba" => "BA", "lt" => "LT", "lv" => "LV", "ee" => "EE",
    "lu" => "LU", "mt" => "MT", "cy" => "CY", "is" => "IS",
    "us" => "US", "eu" => "EU", "bd" => "BD", "np" => "NP", "lk" => "LK",
    "kh" => "KH", "mm" => "MM", "mn" => "MN"
  }

  # ── Two-part country-code TLDs ──
  @two_part_cctld_to_country %{
    "co.uk" => "GB", "org.uk" => "GB", "ac.uk" => "GB", "gov.uk" => "GB", "net.uk" => "GB",
    "com.au" => "AU", "co.au" => "AU", "net.au" => "AU", "org.au" => "AU", "edu.au" => "AU", "gov.au" => "AU",
    "co.nz" => "NZ", "ac.nz" => "NZ", "net.nz" => "NZ", "org.nz" => "NZ",
    "co.za" => "ZA", "net.za" => "ZA", "org.za" => "ZA", "gov.za" => "ZA", "ac.za" => "ZA",
    "co.jp" => "JP", "co.kr" => "KR", "co.in" => "IN", "co.il" => "IL",
    "co.id" => "ID", "co.th" => "TH", "co.ke" => "KE", "co.tz" => "TZ", "co.zw" => "ZW",
    "com.br" => "BR", "net.br" => "BR",
    "com.cn" => "CN", "net.cn" => "CN", "org.cn" => "CN", "edu.cn" => "CN",
    "com.mx" => "MX", "com.ar" => "AR", "com.sg" => "SG", "com.my" => "MY",
    "com.ph" => "PH", "com.tw" => "TW", "com.ua" => "UA", "com.tr" => "TR",
    "com.pk" => "PK", "com.sa" => "SA", "com.eg" => "EG", "com.ng" => "NG",
    "com.gh" => "GH", "com.co" => "CO", "com.pe" => "PE", "com.ve" => "VE",
    "com.hk" => "HK"
  }

  # ── Language → most likely country (for generic TLDs like .com, .org, .net) ──
  @lang_to_country %{
    "fr" => "FR", "de" => "DE", "ja" => "JP", "ko" => "KR",
    "zh" => "CN", "ru" => "RU", "pt" => "BR", "it" => "IT",
    "nl" => "NL", "sv" => "SE", "da" => "DK", "no" => "NO",
    "fi" => "FI", "pl" => "PL", "cs" => "CZ", "hu" => "HU",
    "ro" => "RO", "bg" => "BG", "el" => "GR", "tr" => "TR",
    "th" => "TH", "vi" => "VN", "id" => "ID", "ms" => "MY",
    "uk" => "UA", "he" => "IL", "ar" => "SA", "hi" => "IN",
    "bn" => "BD", "ta" => "IN", "te" => "IN", "es" => "ES",
    "sco" => "GB"
  }

  @doc """
  Infer business country from available signals.

  ## Parameters
    - tld: the TLD from ctl_tld (e.g. "fr", "co.uk", "com")
    - language: detected HTTP language (e.g. "fr", "en", "de")
    - rdap_country: registrant country from RDAP vCard (2-letter code or "")
    - bgp_country: server hosting country from BGP ASN (2-letter code)
  """
  # ASN orgs whose country says where the INFRASTRUCTURE is, never where the
  # merchant is. 2026-08-07 finding: 99.5% of "Canadian" Shopify stores were
  # Cloudflare-fronted .coms, and every English store defaulted to US — so a
  # buyer of a US list got Indian stores that bounce. Unknown beats fabricated.
  @infra_asn_markers ~w(cloudflare fastly akamai shopify squarespace amazon
                        google microsoft wix netlify vercel automattic)

  def infra_asn?(asn_org) when is_binary(asn_org) do
    org = String.downcase(asn_org)
    Enum.any?(@infra_asn_markers, &String.contains?(org, &1))
  end

  def infra_asn?(_), do: false

  def infer(tld, language, rdap_country, bgp_country, asn_org \\ "") do
    tld = normalize(tld)
    lang = normalize_lang(language)
    rdap_cc = normalize_upper(rdap_country)
    bgp_cc = normalize_upper(bgp_country)

    # Priority 1: Country-code TLD
    from_tld(tld) ||
      # Priority 2: Language → country (English says nothing about country)
      from_language(lang) ||
      # Priority 3: RDAP registrant country
      from_rdap(rdap_cc) ||
      # Priority 4: BGP — only when the ASN locates the business, not a CDN
      if(infra_asn?(asn_org), do: nil, else: from_bgp(bgp_cc)) ||
      # No signal: say so. "" is honest; a fabricated US/CA poisons every
      # country-filtered list a customer pays for.
      ""
  end

  @doc """
  The SAME rules as `infer/5`, as a ClickHouse SQL expression over column
  names. Compaction uses this to recompute country from stored signals, which
  is also what makes backfill possible without recrawling. Generated from the
  same maps as the Elixir path — the two cannot drift.
  """
  def sql_expr(tld_col, lang_col, bgp_cc_col, asn_org_col) do
    two_part = sql_map(@two_part_cctld_to_country)
    one_part = sql_map(@cctld_to_country)
    langs = sql_map(@lang_to_country)
    infra = Enum.map_join(@infra_asn_markers, " OR ", &"positionCaseInsensitive(#{asn_org_col}, '#{&1}') > 0")

    """
    multiIf(
      transform(lower(#{tld_col}), #{two_part}, '') != '', transform(lower(#{tld_col}), #{two_part}, ''),
      transform(lower(#{tld_col}), #{one_part}, '') != '', transform(lower(#{tld_col}), #{one_part}, ''),
      transform(splitByChar('-', lower(#{lang_col}))[1], #{langs}, '') != '', transform(splitByChar('-', lower(#{lang_col}))[1], #{langs}, ''),
      (#{infra}), '',
      length(#{bgp_cc_col}) = 2, upper(#{bgp_cc_col}),
      '')
    """
  end

  defp sql_map(map) do
    keys = Enum.map_join(map, ", ", fn {k, _} -> "'#{k}'" end)
    values = Enum.map_join(map, ", ", fn {_, v} -> "'#{v}'" end)
    "[#{keys}], [#{values}]"
  end

  defp from_tld(""), do: nil
  defp from_tld(tld) do
    # Try two-part first (co.uk, com.au), then single-part (fr, de)
    Map.get(@two_part_cctld_to_country, tld) || Map.get(@cctld_to_country, tld)
  end

  defp from_language(""), do: nil
  defp from_language("en"), do: nil  # English handled separately (Priority 4)
  defp from_language(lang), do: Map.get(@lang_to_country, lang)

  defp from_rdap(""), do: nil
  defp from_rdap(cc) when byte_size(cc) == 2, do: cc
  defp from_rdap(_), do: nil

  # BGP country is unreliable when behind CDN/shared hosting.
  # Shopify IPs (23.227.3x.x) always geolocate to Canada regardless of store location.
  defp from_bgp(""), do: nil
  defp from_bgp(cc) when byte_size(cc) == 2, do: cc
  defp from_bgp(_), do: nil

  defp normalize(nil), do: ""
  defp normalize(s), do: s |> String.downcase() |> String.trim()

  defp normalize_lang(nil), do: ""
  defp normalize_lang(s) do
    s |> String.downcase() |> String.trim() |> String.split("-") |> hd()
  end

  defp normalize_upper(nil), do: ""
  defp normalize_upper(s), do: s |> String.upcase() |> String.trim()
end
