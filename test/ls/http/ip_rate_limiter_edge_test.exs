defmodule LS.HTTP.IPRateLimiterEdgeTest do
  @moduledoc """
  Shared edges share one limiter key (2026-10-01). Shopify's 1.4M stores
  resolve to a few addresses in 23.227.38.0/24; keyed per address, every
  node sent one request a second to each of them in parallel and Shopify
  saw one client: 3.6% of Shopify fetches ended in 429 against 0.37%
  fleet-wide, 82,309 stores held a 429 as their last result.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.IPRateLimiter

  test "Shopify edge addresses share one key" do
    assert IPRateLimiter.limiter_key("23.227.38.65") == "edge:shopify"
    assert IPRateLimiter.limiter_key("23.227.38.32") == "edge:shopify"
  end

  test "Wix and Squarespace edges share theirs" do
    assert IPRateLimiter.limiter_key("185.230.63.186") == "edge:wix"
    assert IPRateLimiter.limiter_key("198.49.23.144") == "edge:squarespace"
  end

  test "any other address is its own key, Cloudflare included" do
    assert IPRateLimiter.limiter_key("104.16.132.229") == "104.16.132.229"
    assert IPRateLimiter.limiter_key("1.2.3.4") == "1.2.3.4"
  end

  test "the limiter actually waits between two Shopify stores on different edge addresses" do
    IPRateLimiter.init()
    assert :ok = IPRateLimiter.check_and_update("23.227.38.1", 60_000)
    assert {:wait, ms} = IPRateLimiter.check_and_update("23.227.38.2", 60_000)
    assert ms > 0
  end
end
