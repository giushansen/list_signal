defmodule LS.HTTP.IPRateLimiterHorizonTest do
  @moduledoc """
  2026-11-03, after the ny1 trial: Shopify stores were 23% of a node's
  candidates and a batch starts them together, so a 10 s booking horizon
  at the edge's two seconds booked five and refused the rest (1,110
  refusals in two hours) and the edge's line ran at 7 of its 30 a minute.
  Discovery now books up to 30 s out; the depth lane keeps 10 s because a
  domain there visits up to four pages inside a 120 s task.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.{Client, IPRateLimiter}

  setup do
    IPRateLimiter.init()
    :ets.delete_all_objects(:http_ip_rate_limiter)
    :ets.delete_all_objects(:http_ip_penalty)
    :ok
  end

  test "discovery sleeps up to 30 s for its place, the depth lane up to 10 s" do
    assert Client.book_horizon_ms(:discovery) == 30_000
    assert Client.book_horizon_ms(:enrichment) == 10_000
    assert Client.book_horizon_ms(:unknown) == 10_000
  end

  test "a 30 s horizon books sixteen Shopify stores of a batch start, and refuses the seventeenth" do
    results = for _ <- 1..17, do: IPRateLimiter.book("23.227.38.65", 1_000, 30_000)
    assert Enum.count(results, &match?(:ok, &1)) == 1
    assert Enum.count(results, &match?({:wait, _}, &1)) == 15
    assert [{:refuse, ms}] = Enum.filter(results, &match?({:refuse, _}, &1))
    assert ms > 30_000
    assert {:wait, last} = Enum.at(results, 15)
    assert last > 29_900 and last <= 30_000
  end

  test "the default horizon is still 10 s, so the depth lane's call is unchanged" do
    for _ <- 1..6, do: IPRateLimiter.book("23.227.38.65", 1_000)
    assert {:refuse, _} = IPRateLimiter.book("23.227.38.65", 1_000)
  end

  test "the client passes the lane's horizon and sleeps up to it, not the pause cap" do
    src = File.read!("lib/ls/http/client.ex")
    assert src =~ "@book_horizon_ms %{discovery: 30_000, enrichment: 10_000}"
    assert src =~ "case IPRateLimiter.book(ip, 1000, horizon) do"
    assert src =~ "when retries_left > 0 and wait_ms <= horizon"
  end
end
