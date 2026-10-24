defmodule LS.HTTP.DomainFilterLowYield20261024Test do
  @moduledoc """
  Measured 2026-10-24 on 216K first-contact fetches in a day: GlobalSign
  Atlas R46 DV certificates came back as a real page 13.7% of the time and
  as an ICP business 0.2% (818 fetches, one tier A). Every other TLD,
  issuer and name-shape bucket sat at 40-55% real pages and stays; .top
  (21%) is already an unlisted TLD and skips as such. The sibling GlobalSign
  AlphaSSL issuer was 60% real pages and must not be caught by the prefix.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.DomainFilter

  test "GlobalSign Atlas R46 DV is low yield, whatever the year suffix" do
    assert DomainFilter.low_yield?("shop.example", "GlobalSign Atlas R46 DV TLS CA 2026 Q4")
    assert DomainFilter.low_yield?("shop.example", "GlobalSign Atlas R46 DV TLS CA 2027 Q1")
  end

  test ".top stays what it was: an unlisted TLD, settled by the TLD rule" do
    refute DomainFilter.low_yield?("cheap.top", "")
    assert DomainFilter.verdict("casino-bonus.top", "mx.example", "v=spf1 -all", "203.0.113.10") == {:skip, :tld}
  end

  test "the other GlobalSign issuers and ordinary TLDs are not" do
    refute DomainFilter.low_yield?("shop.example", "GlobalSign GCC R46 AlphaSSL CA 2025")
    refute DomainFilter.low_yield?("shop.example", "GlobalSign Atlas R3 DV TLS CA 2025")
    refute DomainFilter.low_yield?("shop.example", "WE1")
    refute DomainFilter.low_yield?("shop.store", "")
    refute DomainFilter.low_yield?("shop.shop", "")
    refute DomainFilter.low_yield?("topshop.com", "")
  end
end
