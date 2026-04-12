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
  def infer(tld, language, rdap_country, bgp_country) do
    tld = normalize(tld)
    lang = normalize_lang(language)
    rdap_cc = normalize_upper(rdap_country)
    bgp_cc = normalize_upper(bgp_country)

    # Priority 1: Country-code TLD
    from_tld(tld) ||
      # Priority 2: Language → country
      from_language(lang) ||
      # Priority 3: RDAP registrant country
      from_rdap(rdap_cc) ||
      # Priority 4: English → default US
      if(lang == "en", do: "US") ||
      # Priority 5: BGP fallback (skip unreliable CDN countries)
      from_bgp(bgp_cc) ||
      # Default: US (most common for generic TLD with no signal)
      "US"
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
