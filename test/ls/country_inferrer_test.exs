defmodule LS.CountryInferrerTest do
  @moduledoc """
  Country attribution feeds every country filter, /top page and paid list.
  2026-08-07 finding: "English -> US" plus trusting CDN ASNs fabricated
  countries at scale — 99.5% of "Canadian" Shopify stores were
  Cloudflare-fronted .coms and India's 39K stores sat in the US bucket, so a
  buyer of a US list would get Indian stores that bounce. The rule:
  unknown beats fabricated.
  """
  use ExUnit.Case, async: true

  alias LS.CountryInferrer

  @fixtures [
    # {tld, lang, rdap, bgp_cc, asn_org, expected}
    {"in", "en", "", "US", "CLOUDFLARENET - Cloudflare, Inc., US", "IN"},
    {"co.in", "en", "", "US", "", "IN"},
    # Changed 2026-08-27: Hindi is spoken by a diaspora, so `hi` on a .com
    # named India for businesses that were not Indian. A language spoken
    # across many countries now names none of them.
    {"com", "hi", "", "US", "CLOUDFLARENET - Cloudflare, Inc., US", ""},
    {"com", "fr", "", "US", "", "FR"},
    # Reordered 2026-08-27: a registry record outranks a language guess.
    # intellatriage.com, a Nashville business, was labelled French purely
    # because its English page was detected as `fr`.
    {"com", "fr", "US", "", "", "US"},
    # Page evidence outranks everything: a VAT or registration number
    # carries its own country. knowunity.fr is .fr, French-language, and a
    # Berlin company carrying German VAT DE326705352 on its own site.
    {"fr", "fr", "", "US", "", "FR"},
    # The incident cases: English .com on infrastructure ASNs says NOTHING.
    {"com", "en", "", "US", "CLOUDFLARENET - Cloudflare, Inc., US", ""},
    {"com", "en-CA", "", "CA", "SHOPIFY - Shopify, Inc., CA", ""},
    {"com", "en", "", "US", "AMAZON-02 - Amazon.com, Inc., US", ""},
    # Non-infra hosting: BGP is a real (if weak) signal, keep it.
    {"com", "en", "", "IN", "TATA COMMUNICATIONS, IN", "IN"},
    {"com", "en", "", "", "", ""}
  ]

  test "the incident matrix — TLD beats language beats BGP; infra ASNs are mute" do
    for {tld, lang, rdap, bgp, org, expected} <- @fixtures do
      got = CountryInferrer.infer(tld, lang, rdap, bgp, org)

      assert got == expected,
             "infer(#{inspect(tld)}, #{inspect(lang)}, _, #{inspect(bgp)}, #{inspect(org)}) = #{inspect(got)}, want #{inspect(expected)}"
    end
  end

  @tag :data_contract
  test "the SQL expression agrees with the Elixir rules on every fixture" do
    # Compaction recomputes country in ClickHouse from the same maps. If the
    # implementations drift, `businesses` silently disagrees with the app.
    case LS.Clickhouse.query_raw("SELECT 1") do
      {:ok, _} ->
        # Every input the Elixir path takes must reach the SQL path too. The
        # RDAP field used to be dropped here (`_rdap`), so the tier was
        # untested on the SQL side and could have drifted unnoticed.
        expr = CountryInferrer.sql_expr("tld", "lang", "bgp_cc", "asn_org", "evidence", "rdap_cc")

        for {tld, lang, rdap, bgp, org, expected} <- @fixtures do
          sql = """
          SELECT #{expr} FROM (
            SELECT '#{tld}' AS tld, '#{lang}' AS lang, '#{bgp}' AS bgp_cc,
                   '#{org}' AS asn_org, '' AS evidence, '#{rdap}' AS rdap_cc
          )
          """

          {:ok, [[got]]} = LS.Clickhouse.query_raw(sql)

          assert got == expected,
                 "SQL disagrees with Elixir for #{inspect({tld, lang, rdap, bgp, org})}: SQL=#{inspect(got)} Elixir=#{inspect(expected)}"
        end

      _ ->
        :ok
    end
  end

  describe "infer/4 — TLD priority (highest)" do
    test "single-part ccTLD maps to country" do
      assert CountryInferrer.infer("fr", "", nil, "") == "FR"
      assert CountryInferrer.infer("de", "", nil, "") == "DE"
      assert CountryInferrer.infer("jp", "", nil, "") == "JP"
      assert CountryInferrer.infer("ca", "", nil, "") == "CA"
      assert CountryInferrer.infer("uk", "", nil, "") == "GB"
      assert CountryInferrer.infer("au", "", nil, "") == "AU"
      assert CountryInferrer.infer("us", "", nil, "") == "US"
    end

    test "two-part ccTLD maps to country" do
      assert CountryInferrer.infer("co.uk", "", nil, "") == "GB"
      assert CountryInferrer.infer("com.au", "", nil, "") == "AU"
      assert CountryInferrer.infer("co.nz", "", nil, "") == "NZ"
      assert CountryInferrer.infer("co.za", "", nil, "") == "ZA"
      assert CountryInferrer.infer("com.br", "", nil, "") == "BR"
      assert CountryInferrer.infer("co.jp", "", nil, "") == "JP"
      assert CountryInferrer.infer("com.mx", "", nil, "") == "MX"
    end

    test "TLD takes priority over language and BGP" do
      # French TLD but German language — TLD wins
      assert CountryInferrer.infer("fr", "de", nil, "US") == "FR"
      # UK TLD but Japanese language — TLD wins
      assert CountryInferrer.infer("co.uk", "ja", nil, "JP") == "GB"
    end

    test "vanity/tech TLDs are NOT treated as country indicators" do
      # .io, .ai, .co, .me should NOT map to countries
      refute CountryInferrer.infer("io", "", nil, "") == "IO"
      refute CountryInferrer.infer("ai", "", nil, "") == "AI"
      refute CountryInferrer.infer("co", "", nil, "") == "CO"
      refute CountryInferrer.infer("me", "", nil, "") == "ME"
      refute CountryInferrer.infer("tv", "", nil, "") == "TV"
    end

    test "generic TLDs fall through to language" do
      assert CountryInferrer.infer("com", "fr", nil, "") == "FR"
      assert CountryInferrer.infer("org", "de", nil, "") == "DE"
      assert CountryInferrer.infer("store", "ja", nil, "") == "JP"
      assert CountryInferrer.infer("shop", "it", nil, "") == "IT"
    end
  end

  describe "infer/4 — language priority (second)" do
    test "non-English languages map to most likely country" do
      assert CountryInferrer.infer("com", "fr", nil, "") == "FR"
      assert CountryInferrer.infer("com", "de", nil, "") == "DE"
      assert CountryInferrer.infer("com", "ja", nil, "") == "JP"
      assert CountryInferrer.infer("com", "ko", nil, "") == "KR"
      assert CountryInferrer.infer("com", "zh", nil, "") == "CN"
      assert CountryInferrer.infer("com", "ru", nil, "") == "RU"
      assert CountryInferrer.infer("com", "sv", nil, "") == "SE"
    end

    test "a language spoken across many countries names none of them" do
      # 2026-08-27. es -> ES labelled rbj-media.com, a Mexican business,
      # as Spanish. The same shape applied to pt -> BR over Portugal,
      # ar -> SA for twenty countries, and hi/bn/ta/te -> IN for diasporas.
      # For a country-targeted list a wrong country is worse than none.
      assert CountryInferrer.infer("com", "es", nil, "") == ""
      assert CountryInferrer.infer("com", "pt", nil, "") == ""
      assert CountryInferrer.infer("com", "ar", nil, "") == ""
      assert CountryInferrer.infer("com", "hi", nil, "") == ""
    end

    test "English alone attributes nothing" do
      # Changed 2026-08-07: English says nothing about country.
      assert CountryInferrer.infer("com", "en", nil, "") == ""
      assert CountryInferrer.infer("shop", "en", nil, "") == ""
    end

    test "language with region suffix is handled" do
      # "en-US", "fr-CA" etc. — just the first 2 chars
      assert CountryInferrer.infer("com", "fr-CA", nil, "") == "FR"
    end
  end

  describe "infer/4 — RDAP registrant country (third)" do
    test "RDAP country used when TLD and language have no signal" do
      assert CountryInferrer.infer("com", "", "DE", "") == "DE"
      assert CountryInferrer.infer("io", "", "US", "") == "US"
    end

    test "RDAP does not override TLD" do
      assert CountryInferrer.infer("fr", "", "US", "") == "FR"
    end

    test "RDAP now OUTRANKS language" do
      # Reordered 2026-08-27. RDAP registrant country is a registry fact;
      # language is a guess about who the page is written for. Measured on
      # 566 live sites, language scored 73.7% and was still ranked above a
      # registry record, which is how intellatriage.com (Nashville) became
      # French off a bad `fr` detection.
      assert CountryInferrer.infer("com", "de", "US", "") == "US"
      assert CountryInferrer.infer("com", "fr", "US", "") == "US"
    end
  end

  describe "infer/4 — BGP fallback (lowest)" do
    test "BGP used when nothing else available" do
      assert CountryInferrer.infer("xyz", "", nil, "DE") == "DE"
    end

    test "BGP does not override TLD or language" do
      assert CountryInferrer.infer("fr", "", nil, "US") == "FR"
      assert CountryInferrer.infer("com", "de", nil, "US") == "DE"
    end
  end

  describe "infer/4 — default fallback" do
    test "no signal at all is honest empty, never a default" do
      # Changed 2026-08-07: no signal means "", never a fabricated US. The
      # en->US default had swallowed India's 39K Shopify stores.
      assert CountryInferrer.infer("com", "", nil, "") == ""
      assert CountryInferrer.infer("", "", nil, "") == ""
      assert CountryInferrer.infer(nil, nil, nil, nil) == ""
    end
  end

  describe "infer/4 — nil handling" do
    test "nil inputs are handled gracefully" do
      assert CountryInferrer.infer(nil, nil, nil, nil) == ""
      assert CountryInferrer.infer(nil, "fr", nil, nil) == "FR"
      assert CountryInferrer.infer("de", nil, nil, nil) == "DE"
    end
  end
end
