defmodule LS.LandingQueriesSourceTest do
  @moduledoc """
  2026-10-28: the landing's "technologies tracked" count and the recent
  Shopify teaser scanned `domains` and `domains_fast` (301M and 193M rows)
  at 9.0 s and 9.5 s, 60 times a day each, on the box that serves the
  dashboard. The product table gives the same numbers in 1.3 s and 0.66 s.
  Pinned by reading the source: the queries are strings inside cached
  functions and a unit test cannot run them without ClickHouse.
  """
  use ExUnit.Case, async: true

  @landing File.read!("lib/ls/landing_cache.ex")
  @clickhouse File.read!("lib/ls/clickhouse.ex")

  test "tech_count and app_count read businesses, not domains" do
    for key <- ["tech_count", "app_count"] do
      line = @landing |> String.split("\n") |> Enum.find(&String.contains?(&1, "#{key}: slow("))
      assert line =~ "FROM businesses", "#{key} must scan the product table"
      refute line =~ "FROM domains", "#{key} scanned 301M domain rows at 9 s"
    end
  end

  test "recent_stores reads businesses ordered by the check time, same row shape as before" do
    fun = @clickhouse |> String.split("def recent_stores") |> Enum.at(1) |> String.slice(0, 900)
    assert fun =~ "FROM businesses"
    refute fun =~ "FROM domains_fast"
    assert fun =~ "SELECT domain, estimated_country, http_title, arrayStringConcat(http_tech, '|'), http_last_checked_at"
    assert fun =~ "ORDER BY http_last_checked_at DESC"
  end

  test "similar stores stay cached for a day: a miss is a full scan of the product table" do
    assert @clickhouse =~ "@similar_stores_ttl :timer.hours(24)"
  end
end
