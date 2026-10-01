defmodule LS.HTTP.NeverContactStemsTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.NeverContact

  @moduledoc """
  2026-10-01: fourth Vultr abuse report, from the first domain ever put on
  the never-contact list. morbihan-genealogie.bzh was refused as listed,
  and the same owner's site on .net, .org, .be, .info, .biz, .fr and .eu
  (one site, one address, eight names) was fetched by seven nodes on 09-30;
  their WAF answered 503 and reported the canonical .bzh host. A reporter
  is a name, not a TLD: every listed domain's registrable label now blocks
  that label under any suffix.
  """

  test "a listed domain blocks its name on every TLD, under www, and under co.uk-style suffixes" do
    for d <- ~w(morbihan-genealogie.bzh morbihan-genealogie.net www.morbihan-genealogie.org morbihan-genealogie.co.uk
                xayann-services.com xayann-services.fr shinhangroup.co.kr) do
      assert NeverContact.blocked?(d), d
    end
  end

  test "the stem is the registrable label, so lookalikes and partial names are not blocked" do
    refute NeverContact.blocked?("morbihan-genealogie-tours.fr")
    refute NeverContact.blocked?("genealogie.bzh")
    refute NeverContact.blocked?("example.com")
    # The owner's rule from never_contact_test.exs: a reporter's name as
    # someone else's subdomain is a lookalike, not the reporter.
    refute NeverContact.blocked?("xayann-services.com.evil.example")
    refute NeverContact.blocked?("morbihan-genealogie.evil.example")
  end

  test "the registrable label is read correctly on both suffix shapes" do
    assert NeverContact.registrable_label("www.morbihan-genealogie.net") == "morbihan-genealogie"
    assert NeverContact.registrable_label("morbihan-genealogie.co.uk") == "morbihan-genealogie"
    assert NeverContact.registrable_label("shinhangroup.co.kr") == "shinhangroup"
    assert NeverContact.registrable_label("xayann-services.com.evil.example") == "evil"
    assert NeverContact.registrable_label("localhost") == nil
  end

  test "every stem is long enough that no generic label can block the web" do
    refute Enum.empty?(NeverContact.stems())
    assert Enum.all?(NeverContact.stems(), &(String.length(&1) >= 6))
    assert "morbihan-genealogie" in NeverContact.stems()
  end

  test "the browser gate receives the stems too" do
    assert "morbihan-genealogie" in LS.Enrichment.Browser.blocked_list()
  end
end
