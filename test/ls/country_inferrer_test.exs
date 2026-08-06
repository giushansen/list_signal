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
    {"com", "hi", "", "US", "CLOUDFLARENET - Cloudflare, Inc., US", "IN"},
    {"com", "fr", "", "US", "", "FR"},
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
        expr = CountryInferrer.sql_expr("tld", "lang", "bgp_cc", "asn_org")

        for {tld, lang, _rdap, bgp, org, expected} <- @fixtures do
          sql = """
          SELECT #{expr} FROM (
            SELECT '#{tld}' AS tld, '#{lang}' AS lang, '#{bgp}' AS bgp_cc, '#{org}' AS asn_org
          )
          """

          {:ok, [[got]]} = LS.Clickhouse.query_raw(sql)

          assert got == expected,
                 "SQL disagrees with Elixir for #{inspect({tld, lang, bgp, org})}: SQL=#{inspect(got)} Elixir=#{inspect(expected)}"
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
      assert CountryInferrer.infer("com", "pt", nil, "") == "BR"
      assert CountryInferrer.infer("com", "es", nil, "") == "ES"
      assert CountryInferrer.infer("com", "sv", nil, "") == "SE"
      assert CountryInferrer.infer("com", "sco", nil, "") == "GB"
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

    test "RDAP does not override language" do
      assert CountryInferrer.infer("com", "de", "US", "") == "DE"
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
