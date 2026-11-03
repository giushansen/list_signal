defmodule LS.HTTP.IPRateLimiterBackoffTest do
  @moduledoc """
  2026-11-03: 92.4% of the fleet's 429s in a day came from the Shopify edge
  (4,188 of 82,906 Shopify fetches, 5.05%; 15.9% on sg2) at one request a
  second per node, and nothing read Retry-After or slowed down after a
  refusal. The edge now gets two seconds per node, and a 429 pauses its
  key on a doubling schedule or for Retry-After, whichever is longer.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.IPRateLimiter

  setup do
    IPRateLimiter.init()
    :ets.delete_all_objects(:http_ip_rate_limiter)
    :ets.delete_all_objects(:http_ip_penalty)
    :ok
  end

  test "the Shopify edge is held to two seconds whatever the caller asks" do
    assert IPRateLimiter.min_spacing_ms("23.227.38.65") == 2_000
    assert IPRateLimiter.min_spacing_ms("104.16.132.229") == 0
    assert :ok = IPRateLimiter.check_and_update("23.227.38.65", 1_000)
    assert {:wait, ms} = IPRateLimiter.check_and_update("23.227.38.66", 1_000)
    assert ms > 1_000 and ms <= 2_000
  end

  test "a 429 pauses the key for five seconds, the next one for ten, up to five minutes" do
    assert IPRateLimiter.penalize("1.2.3.4") == 5_000
    assert IPRateLimiter.penalize("1.2.3.4") == 10_000
    assert IPRateLimiter.penalize("1.2.3.4") == 20_000
    for _ <- 1..10, do: IPRateLimiter.penalize("1.2.3.4")
    assert IPRateLimiter.penalize("1.2.3.4") == 300_000
  end

  test "Retry-After longer than the schedule wins; shorter does not shorten it" do
    assert IPRateLimiter.penalize("5.6.7.8", 42_000) == 42_000
    assert IPRateLimiter.penalize("5.6.7.9", 1_000) == 5_000
  end

  test "a paused key refuses with the remaining wait, and a store's 429 pauses the whole edge" do
    IPRateLimiter.penalize("23.227.38.1")
    assert {:wait, ms} = IPRateLimiter.check_and_update("23.227.38.200", 1_000)
    assert ms > 4_000 and ms <= 5_000
    assert :ok = IPRateLimiter.check_and_update("9.9.9.9", 1_000), "another key is not paused"
  end

  test "penalties are counted in the stats" do
    before = IPRateLimiter.stats().penalties
    IPRateLimiter.penalize("8.8.8.8")
    assert IPRateLimiter.stats().penalties == before + 1
  end

  test "a hostile Retry-After never pauses longer than five minutes" do
    assert IPRateLimiter.penalize("4.4.4.4", 86_400_000) == 300_000
  end
end
