defmodule LS.HTTP.DomainFilterVerdictTest do
  @moduledoc """
  The crawl filter explains itself (2026-10-01). Measured on prod that
  day: 189M resolved domains had never been fetched, 60% of every row the
  fleet wrote. Among them 18M on the Shopify, Wix and Squarespace edges
  (4.56M on Shopify's alone, 1.75M of those with MX) and 19M with MX at a
  known business mail provider and no SPF record. The verdict keeps the
  skip for names and TLDs that settle the question, and crawls the two
  groups the ICP pays for.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.DomainFilter

  setup_all do
    DomainFilter.load_tlds()
    :ok
  end

  @spf "v=spf1 include:_spf.google.com ~all"

  test "a listed TLD with MX and SPF crawls, as before" do
    assert DomainFilter.verdict("acme-tools.com", "aspmx.l.google.com", @spf) == :crawl
    assert DomainFilter.should_crawl?("acme-tools.com", "aspmx.l.google.com", @spf)
  end

  test "a Shopify, Wix or Squarespace edge address crawls whatever the TLD or mail setup" do
    assert DomainFilter.verdict("sunnycandles.shop", "", "", "23.227.38.65") == :crawl
    assert DomainFilter.verdict("studio-nine.com.au", "", "", "198.185.159.144") == :crawl
    assert DomainFilter.verdict("florist.online", "", "", "185.230.63.107") == :crawl
  end

  test "MX at a known business mail provider crawls without SPF" do
    assert DomainFilter.verdict("brightlaw.co.uk", "brightlaw-co-uk.mail.protection.outlook.com", "") == :crawl
    assert DomainFilter.verdict("bakery.de", "aspmx.l.google.com|alt1.aspmx.l.google.com", "") == :crawl
  end

  test "a listed TLD with no mail setup is a soft skip, re-evaluated later" do
    assert DomainFilter.verdict("newbrand.com", "", "", "203.0.113.10") == {:skip, :no_mail}
    assert DomainFilter.verdict("newbrand.com", "mx.unknown-host.example", "", "203.0.113.10") == {:skip, :no_mail}
  end

  test "an unlisted TLD and a junk name are settled skips" do
    assert DomainFilter.verdict("casino-bonus.top", "mx.example", @spf, "203.0.113.10") == {:skip, :tld}
    assert DomainFilter.verdict("18fuli180.cc", "", "", "203.0.113.10") == {:skip, :junk_name}
    assert DomainFilter.verdict("a-b-c.com", "mx.example", @spf) == {:skip, :junk_name}
  end

  test "a junk name is junk even on a commerce edge" do
    assert DomainFilter.verdict("303018.lol", "", "", "23.227.38.65") == {:skip, :junk_name}
  end

  test "the three-argument form still works for older callers" do
    refute DomainFilter.should_crawl?("aa.io", "", "")
    refute DomainFilter.should_crawl?("example123456.com", "mx.google.com", "random txt")
  end
end
