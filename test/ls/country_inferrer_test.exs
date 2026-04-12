defmodule LS.CountryInferrerTest do
  use ExUnit.Case, async: true

  alias LS.CountryInferrer

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

    test "English defaults to US (not via language map)" do
      assert CountryInferrer.infer("com", "en", nil, "") == "US"
      assert CountryInferrer.infer("shop", "en", nil, "") == "US"
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
    test "no signal at all defaults to US" do
      assert CountryInferrer.infer("com", "", nil, "") == "US"
      assert CountryInferrer.infer("", "", nil, "") == "US"
      assert CountryInferrer.infer(nil, nil, nil, nil) == "US"
    end
  end

  describe "infer/4 — nil handling" do
    test "nil inputs are handled gracefully" do
      assert CountryInferrer.infer(nil, nil, nil, nil) == "US"
      assert CountryInferrer.infer(nil, "fr", nil, nil) == "FR"
      assert CountryInferrer.infer("de", nil, nil, nil) == "DE"
    end
  end
end
