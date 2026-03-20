defmodule LS.HTTP.DomainFilterTest do
  use ExUnit.Case, async: false

  alias LS.HTTP.DomainFilter

  setup_all do
    DomainFilter.load_tlds()
    :ok
  end

  # ============================================================================
  # SHOULD CRAWL — valid domains
  # ============================================================================

  test "accepts .com domain with MX and SPF" do
    assert DomainFilter.should_crawl?(
      "example.com",
      "10:aspmx.l.google.com",
      "v=spf1 include:_spf.google.com ~all"
    )
  end

  test "accepts .io domain with MX and SPF" do
    assert DomainFilter.should_crawl?(
      "myapp.io",
      "10:smtp.google.com",
      "v=spf1 include:_spf.google.com ~all"
    )
  end

  test "accepts .co.uk domain with MX and SPF" do
    assert DomainFilter.should_crawl?(
      "business.co.uk",
      "10:mail.example.co.uk",
      "v=spf1 ip4:1.2.3.4 ~all"
    )
  end

  # ============================================================================
  # SHOULD NOT CRAWL — filtered out
  # ============================================================================

  test "rejects domain without MX records" do
    refute DomainFilter.should_crawl?(
      "nomail.com",
      "",
      "v=spf1 include:_spf.google.com ~all"
    )
  end

  test "rejects domain without SPF" do
    refute DomainFilter.should_crawl?(
      "nospf.com",
      "10:mx.example.com",
      "google-site-verification=abc123"
    )
  end

  test "rejects very short domain" do
    refute DomainFilter.should_crawl?(
      "aa.io",
      "10:mx.aa.io",
      "v=spf1 ~all"
    )
  end

  test "rejects domain with no MX and no SPF" do
    refute DomainFilter.should_crawl?("naked.com", "", "")
  end

  # ============================================================================
  # TLD LOADING
  # ============================================================================

  test "TLDs are loaded into ETS" do
    size = :ets.info(:http_high_value_tlds, :size)
    assert size > 30, "Expected 30+ high-value TLDs, got #{size}"
  end

  test ".com is a high-value TLD" do
    assert :ets.lookup(:http_high_value_tlds, "com") != []
  end

  test ".io is a high-value TLD" do
    assert :ets.lookup(:http_high_value_tlds, "io") != []
  end
end
