defmodule LS.HTTP.ClientHopBookingTest do
  @moduledoc """
  2026-11-04: a redirect hop asked the limiter for a slot within 5 s and
  gave up otherwise. Once discovery booked the Shopify line up to 30 s
  ahead (8bfd7a7, deployed 2026-11-03 15:43 UTC) the apex-to-www hop of a
  Shopify store rarely found 5 s and the store ended as a bare 301 row
  with no content: 3 to 6% of Shopify rows were 301 before, 17 to 25%
  after, about 1,000 stores an hour. A hop now books its place like any
  first contact, within its lane's horizon.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.{Client, IPRateLimiter}

  @shopify_a "23.227.38.65"
  @shopify_b "23.227.38.66"

  setup do
    IPRateLimiter.init()
    :ets.delete(:http_ip_rate_limiter, "edge:shopify")
    :ets.delete(:http_ip_penalty, "edge:shopify")
    on_exit(fn ->
      :ets.delete(:http_ip_rate_limiter, "edge:shopify")
      :ets.delete(:http_ip_penalty, "edge:shopify")
    end)
    :ok
  end

  defp book_ahead(n), do: for(_ <- 1..n, do: IPRateLimiter.book(@shopify_a, 1_000, 60_000))

  test "an idle line is taken at once" do
    assert :ok = Client.hop_booking("198.51.100.7", :discovery)
  end

  test "a hop waits for its place on a line booked more than 5 s ahead" do
    # Four bookings on the 2 s edge: the next place is 6 to 8 s out, where
    # the old check gave up.
    book_ahead(4)
    assert {:wait, ms} = Client.hop_booking(@shopify_b, :discovery)
    assert ms > 5_000 and ms <= 8_000
  end

  test "a hop sleeps up to its lane's horizon and no further" do
    book_ahead(6)
    assert {:wait, ms} = Client.hop_booking(@shopify_b, :discovery)
    assert ms <= Client.book_horizon_ms(:discovery)
    # The same line is too deep for the depth lane's 10 s.
    assert :stop = Client.hop_booking(@shopify_b, :enrichment)
  end

  test "a hop beyond the horizon is refused and books nothing" do
    book_ahead(16)
    [{_, before}] = :ets.lookup(:http_ip_rate_limiter, "edge:shopify")
    assert :stop = Client.hop_booking(@shopify_b, :discovery)
    assert [{_, ^before}] = :ets.lookup(:http_ip_rate_limiter, "edge:shopify")
  end

  test "a paused edge refuses the hop" do
    IPRateLimiter.penalize(@shopify_a)
    assert :stop = Client.hop_booking(@shopify_b, :discovery)
  end

  test "every hop books the line, the same host's included" do
    src = File.read!("lib/ls/http/client.ex")
    assert src =~ ":ok <- pace(new_ip),\n                   :ok <- hop_slot() do"
    refute src =~ "check_and_update(ip, 1000) == :ok, do: :ok, else: :stop"
  end
end
