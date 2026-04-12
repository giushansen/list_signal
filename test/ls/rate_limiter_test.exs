defmodule LS.RateLimiterTest do
  use ExUnit.Case, async: false

  alias LS.RateLimiter

  setup do
    RateLimiter.init()
    :ok
  end

  test "free users limited to 10 req/min" do
    user_id = "test_free_#{System.unique_integer([:positive])}"
    for _ <- 1..10, do: assert(RateLimiter.check(user_id, "free") == :ok)
    assert RateLimiter.check(user_id, "free") == {:error, :rate_limited}
  end

  test "starter users limited to 30 req/min" do
    user_id = "test_starter_#{System.unique_integer([:positive])}"
    for _ <- 1..30, do: assert(RateLimiter.check(user_id, "starter") == :ok)
    assert RateLimiter.check(user_id, "starter") == {:error, :rate_limited}
  end

  test "pro users limited to 120 req/min" do
    user_id = "test_pro_#{System.unique_integer([:positive])}"
    for _ <- 1..120, do: assert(RateLimiter.check(user_id, "pro") == :ok)
    assert RateLimiter.check(user_id, "pro") == {:error, :rate_limited}
  end

  test "stats returns correct usage without incrementing" do
    user_id = "test_stats_#{System.unique_integer([:positive])}"
    RateLimiter.check(user_id, "starter")
    RateLimiter.check(user_id, "starter")

    stats = RateLimiter.stats(user_id, "starter")
    assert stats.used == 2
    assert stats.limit == 30
    assert stats.remaining == 28
  end
end
