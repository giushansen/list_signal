defmodule LS.HTTP.DomainFilterLowYieldTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.DomainFilter

  @moduledoc """
  2026-10-02, measured over 951K first-time fetches: the business yield of
  every pre-fetch feature sat at 10-25%, except ZeroSSL-issued names (4.7%,
  11K fetches a day) and .xyz (5.3%, 5K a day). Those two are settled skips.
  Everything else keeps crawling: the data does not support more.
  """

  setup_all do
    DomainFilter.load_tlds()
    :ok
  end

  test "a ZeroSSL certificate or a .xyz name is a low-yield skip" do
    assert DomainFilter.low_yield?("shop.example", "ZeroSSL RSA Domain Secure Site CA")
    assert DomainFilter.low_yield?("shop.example", "ZeroSSL ECC DV SSL CA")
    assert DomainFilter.low_yield?("cheap.xyz", "")
    assert DomainFilter.low_yield?("CHEAP.XYZ", nil)
    refute DomainFilter.low_yield?("shop.example", "R11")
    refute DomainFilter.low_yield?("shop.example", "")
  end

  test "the verdict skips low-yield names as settled, after the junk-name and edge rules" do
    assert {:skip, :low_yield} = DomainFilter.verdict("some-shop.com", "mx.example", "v=spf1 -all", "203.0.113.5", "ZeroSSL ECC DV SSL CA")
    assert {:skip, :junk_name} = DomainFilter.verdict("a-b-c.com", "mx.example", "v=spf1 -all", "203.0.113.5", "ZeroSSL ECC DV SSL CA")
    assert :crawl = DomainFilter.verdict("some-shop.com", "mx.example", "v=spf1 -all", "203.0.113.5", "R11")
    # A commerce edge is stronger evidence than a cheap certificate.
    assert :crawl = DomainFilter.verdict("some-shop.com", "", "", "23.227.38.65", "ZeroSSL ECC DV SSL CA")
  end

  test "the four-argument form still works for callers without an issuer" do
    assert :crawl = DomainFilter.verdict("some-shop.com", "mx.example", "v=spf1 -all", "203.0.113.5")
  end
end
