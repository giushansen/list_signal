defmodule LS.HTTP.DomainFilterLowYield20261024Test do
  @moduledoc """
  Measured 2026-10-24 on 216K first-contact fetches in a day: GlobalSign
  Atlas R46 DV certificates came back as a real page 13.7% of the time and
  as an ICP business 0.2% (818 fetches, one tier A); .top names 21.3% and
  1.2% (249). Every other TLD, issuer and name-shape bucket sat at 40-55%
  real pages and stays. The sibling GlobalSign AlphaSSL issuer was 60%
  real pages and must not be caught by the prefix.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.DomainFilter

  test "GlobalSign Atlas R46 DV and .top are low yield" do
    assert DomainFilter.low_yield?("shop.example", "GlobalSign Atlas R46 DV TLS CA 2026 Q4")
    assert DomainFilter.low_yield?("shop.example", "GlobalSign Atlas R46 DV TLS CA 2027 Q1")
    assert DomainFilter.low_yield?("cheap.top", "")
    assert DomainFilter.low_yield?("CHEAP.TOP", nil)
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
