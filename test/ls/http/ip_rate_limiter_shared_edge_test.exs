defmodule LS.HTTP.IPRateLimiterSharedEdgeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-11-03: a tier A refresh wave started 60 to 190 Shopify stores per
  node at once; the 2 s edge line booked 16 inside the 30 s horizon and
  refused the rest, and a store refused twice in one wave was shelved
  for its cadence (350 to 835 a wave). The worker now runs targets behind
  a shared edge in a narrow lane, and this is the test that decides which.
  """

  alias LS.HTTP.IPRateLimiter

  test "addresses behind Shopify, Squarespace and Wix are shared-edge targets" do
    for ip <- ~w(23.227.38.65 23.227.38.32 198.185.159.144 198.49.23.145 185.230.63.171 23.236.62.147) do
      assert IPRateLimiter.shared_edge?(ip), ip
      assert String.starts_with?(IPRateLimiter.limiter_key(ip), "edge:")
    end
  end

  test "an ordinary address, a Cloudflare address and junk are not" do
    refute IPRateLimiter.shared_edge?("104.21.21.152"), "Cloudflare limits per zone, never one line for 5.9M sites"
    refute IPRateLimiter.shared_edge?("23.227.39.1"), "a neighbouring prefix is not the edge"
    refute IPRateLimiter.shared_edge?("")
    refute IPRateLimiter.shared_edge?(nil)
    refute IPRateLimiter.shared_edge?(:no_ip)
  end
end
