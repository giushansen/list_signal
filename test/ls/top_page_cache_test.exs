defmodule LS.TopPageCacheTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The /top/* ranking queries are cached.

  Measured 2026-08-27 on prod: the per-country variant was the single most
  expensive query on the box, 160 calls in 6 hours at ~100s and 9.75 GiB read
  each, roughly 0.75 of a core burning continuously. `domains_fast` is a VIEW
  with no sorting key, so every call re-scans the base table and there is no
  index to add. These are public ranking pages that barely move within a day,
  so they are computed on a TTL instead of per request.
  """

  test "the top_page profile exists and its TTL is long enough to matter" do
    assert {ttl, _} = LS.UICache.profiles()[:top_page]
    assert ttl >= 600, "a short TTL puts the 100-second scan back on the request path"
  end

  test "a repeated country lookup computes once" do
    key = {:country, "ZZ", 50}
    LS.UICache.invalidate(:top_page, key)
    hits = :counters.new(1, [])

    compute = fn ->
      :counters.add(hits, 1, 1)
      {:ok, [["a.example", "t", "", "ZZ", 1]]}
    end

    assert LS.UICache.fetch(:top_page, key, compute) == {:ok, [["a.example", "t", "", "ZZ", 1]]}
    assert LS.UICache.fetch(:top_page, key, compute) == {:ok, [["a.example", "t", "", "ZZ", 1]]}
    assert :counters.get(hits, 1) == 1, "second request must not re-run the scan"

    LS.UICache.invalidate(:top_page, key)
  end

  test "different countries and techs do not share a cache entry" do
    for k <- [{:country, "ES", 50}, {:country, "FR", 50}, {:tech, "Klaviyo", 50}] do
      LS.UICache.invalidate(:top_page, k)
    end

    LS.UICache.fetch(:top_page, {:country, "ES", 50}, fn -> {:ok, [:es]} end)
    LS.UICache.fetch(:top_page, {:country, "FR", 50}, fn -> {:ok, [:fr]} end)
    LS.UICache.fetch(:top_page, {:tech, "Klaviyo", 50}, fn -> {:ok, [:kl]} end)

    assert LS.UICache.fetch(:top_page, {:country, "ES", 50}, fn -> {:ok, [:wrong]} end) == {:ok, [:es]}
    assert LS.UICache.fetch(:top_page, {:country, "FR", 50}, fn -> {:ok, [:wrong]} end) == {:ok, [:fr]}
    assert LS.UICache.fetch(:top_page, {:tech, "Klaviyo", 50}, fn -> {:ok, [:wrong]} end) == {:ok, [:kl]}
  end

  test "an error result is never cached, so a ClickHouse blip cannot pin an empty page" do
    key = {:country, "YY", 50}
    LS.UICache.invalidate(:top_page, key)

    assert LS.UICache.fetch(:top_page, key, fn -> {:error, :timeout} end) == {:error, :timeout}
    assert LS.UICache.fetch(:top_page, key, fn -> {:ok, [:recovered]} end) == {:ok, [:recovered]}

    LS.UICache.invalidate(:top_page, key)
  end
end
