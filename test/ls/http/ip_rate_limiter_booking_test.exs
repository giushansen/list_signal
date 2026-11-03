defmodule LS.HTTP.IPRateLimiterBookingTest do
  @moduledoc """
  2026-11-03, two hours into the ny1 trial: the ten Shopify candidates a
  batch started at once all slept the edge's two seconds and raced again,
  and the losers burned the node budget slot they already held: 15% of
  the first half hour's rows and 5.7% of the first two hours' came back
  as our own refusals, with the edge's line under-used the whole time.
  `book/2` gives concurrent callers consecutive places in the key's line.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.IPRateLimiter

  setup do
    IPRateLimiter.init()
    :ets.delete_all_objects(:http_ip_rate_limiter)
    :ets.delete_all_objects(:http_ip_penalty)
    :ok
  end

  test "concurrent bookings on one key are spaced one after the other, never the same slot" do
    assert :ok = IPRateLimiter.book("23.227.38.65", 1_000)
    assert {:wait, a} = IPRateLimiter.book("23.227.38.66", 1_000)
    assert {:wait, b} = IPRateLimiter.book("23.227.38.67", 1_000)
    assert {:wait, c} = IPRateLimiter.book("23.227.38.68", 1_000)
    assert a > 1_900 and a <= 2_000, "the edge's two seconds, not the caller's one"
    assert b - a >= 1_990 and b - a <= 2_010
    assert c - b >= 1_990 and c - b <= 2_010
  end

  test "a per-address key keeps the caller's spacing" do
    assert :ok = IPRateLimiter.book("9.9.9.9", 1_000)
    assert {:wait, a} = IPRateLimiter.book("9.9.9.9", 1_000)
    assert {:wait, b} = IPRateLimiter.book("9.9.9.9", 1_000)
    assert a > 900 and a <= 1_000
    assert b - a >= 990 and b - a <= 1_010
  end

  test "a line booked more than ten seconds ahead refuses and reserves nothing" do
    for _ <- 1..6, do: IPRateLimiter.book("23.227.38.1", 1_000)
    assert {:refuse, ms} = IPRateLimiter.book("23.227.38.2", 1_000)
    assert ms > 10_000
    # The refusal did not move the line: the next booking lands where the
    # refused one would have.
    assert {:refuse, ms2} = IPRateLimiter.book("23.227.38.3", 1_000)
    assert abs(ms2 - ms) < 50
  end

  test "a paused key refuses with the remaining pause" do
    IPRateLimiter.penalize("23.227.38.1")
    assert {:refuse, ms} = IPRateLimiter.book("23.227.38.9", 1_000)
    assert ms > 4_000 and ms <= 5_000
  end

  test "an old booking is claimed by exactly one caller, the rest line up behind it" do
    :ets.insert(:http_ip_rate_limiter, {"7.7.7.7", System.monotonic_time(:millisecond) - 60_000})

    results =
      1..5
      |> Task.async_stream(fn _ -> IPRateLimiter.book("7.7.7.7", 1_000) end, max_concurrency: 5)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    waits = for {:wait, ms} <- results, do: ms
    assert length(waits) == 4
    assert Enum.sort(waits) |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [x, y] -> y - x >= 990 end)
  end

  test "bookings and refusals count as waits in the stats" do
    before = IPRateLimiter.stats().total_waits
    IPRateLimiter.book("6.6.6.6", 1_000)
    IPRateLimiter.book("6.6.6.6", 1_000)
    assert IPRateLimiter.stats().total_waits == before + 1
  end

  test "the client books the key after the node slot, and gives the slot back on a refusal" do
    src = File.read!("lib/ls/http/client.ex")
    [_, after_budget] = String.split(src, "case LS.HTTP.NodeBudget.take(LS.HTTP.NodeBudget.lane_limit(lane), lane) do", parts: 2)
    assert after_budget =~ "case IPRateLimiter.book(ip, 1000) do"
    assert after_budget =~ "LS.HTTP.NodeBudget.release(LS.HTTP.NodeBudget.lane_limit(lane), lane)"
    refute after_budget =~ "IPRateLimiter.check_and_update(ip, 1000) do\n      :ok ->\n        fetch_with_redirects"
  end
end
