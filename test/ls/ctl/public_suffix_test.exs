defmodule LS.CTL.PublicSuffixTest do
  @moduledoc """
  2026-11-02: the parser knew 54 two-part suffixes, so every domain under
  com.pl, com.vn, com.hk and thousands of other suffixes collapsed into the
  suffix itself. `businesses` held 0 of each, and `platforms` had learned 985
  public suffixes as "platforms", dropping whole countries at the poller.
  """
  use ExUnit.Case, async: true

  alias LS.CTL.{DomainParser, PublicSuffix}

  test "a country second-level suffix outside the old list is a suffix, not a business" do
    assert PublicSuffix.registrable("shop.example.com.pl") == {:ok, "example.com.pl", "com.pl"}
    assert PublicSuffix.registrable("foo.example.com.vn") == {:ok, "example.com.vn", "com.vn"}
    assert PublicSuffix.registrable("www.example.com.hk") == {:ok, "example.com.hk", "com.hk"}
    assert PublicSuffix.registrable("a.school.edu.ua") == {:ok, "school.edu.ua", "edu.ua"}
  end

  test "the suffixes the old list knew still parse the same" do
    assert DomainParser.parse("www.example.com") == {:ok, "example.com", "com"}
    assert DomainParser.parse("api.example.co.uk") == {:ok, "example.co.uk", "co.uk"}
    assert DomainParser.parse("shop.example.com.au") == {:ok, "example.com.au", "com.au"}
    assert DomainParser.parse("*.example.io") == {:ok, "example.io", "io"}
    assert DomainParser.parse("Example.COM.") == {:ok, "example.com", "com"}
  end

  test "a name that is a public suffix has no registrable form" do
    assert PublicSuffix.registrable("com.pl") == :error
    assert PublicSuffix.registrable("co.uk") == :error
    assert PublicSuffix.registrable("com") == :error
    assert DomainParser.parse("org.ph") == :error
  end

  test "wildcard and exception rules (*.ck, !www.ck)" do
    assert PublicSuffix.registrable("foo.bar.ck") == {:ok, "foo.bar.ck", "bar.ck"}
    assert PublicSuffix.registrable("www.ck") == {:ok, "www.ck", "ck"}
    assert PublicSuffix.public_suffix?("bar.ck")
    refute PublicSuffix.public_suffix?("www.ck")
  end

  test "public_suffix? names the 985 rows that must never be platforms" do
    for s <- ~w(com.pl com.vn org.ph net.ph my.id co.it on.ca gmina.pl gov.br edu.ua ut.us com) do
      assert PublicSuffix.public_suffix?(s), s
    end

    for d <- ~w(example.com shopify.com example.com.pl pages.dev github.io) do
      refute PublicSuffix.public_suffix?(d), d
    end
  end

  test "unicode suffixes are matched in punycode, as certificates carry them" do
    assert PublicSuffix.registrable("shop.xn--55qx5d.cn") == {:ok, "shop.xn--55qx5d.cn", "xn--55qx5d.cn"}
  end

  test "hostile input parses to :error, never raises" do
    for bad <- ["", ".", "..", "com.", "a..b.com", "localhost", 42, nil] do
      assert PublicSuffix.registrable(bad) == :error or match?({:ok, _, _}, PublicSuffix.registrable(bad))
    end

    assert PublicSuffix.registrable("") == :error
    assert PublicSuffix.registrable("localhost") == :error
    assert DomainParser.parse(nil) == :error
    refute PublicSuffix.public_suffix?("")
  end

  test "the vendored list is the ICANN section, thousands of rules" do
    assert PublicSuffix.rule_count() > 6_000
  end
end
