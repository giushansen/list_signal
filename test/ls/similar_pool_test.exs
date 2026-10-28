defmodule LS.SimilarPoolTest do
  @moduledoc """
  2026-10-28: the "businesses like this one" block scanned the product
  table on every cache miss (3 to 15 s, 176 misses in six hours on the box
  that serves customers, because crawlers walk a different company page
  each time). The candidates now come from `similar_pool`, pre-selected per
  (model, country, revenue tier) and read by key. These pin the build, the
  read, the schedule and the fallback.
  """
  use ExUnit.Case, async: true

  alias LS.SimilarPool

  @migration File.read!("clickhouse/migrations/031_similar_pool.sql")
  @clickhouse File.read!("lib/ls/clickhouse.ex")

  test "the build keeps at most 80 ranked and 40 recent candidates per group, filtered like the page" do
    sql = SimilarPool.build_sql("similar_pool_build")
    assert sql =~ "INSERT INTO similar_pool_build"
    assert sql =~ "LIMIT 80 BY business_model, country, revenue"
    assert sql =~ "LIMIT 40 BY business_model, country, revenue"
    assert sql =~ "'ranked' AS kind"
    assert sql =~ "'recent' AS kind"
    # The page's own filters, so the pool never offers what the scan refused.
    assert sql =~ "estimated_business_model_confidence >= 0.5 AND estimated_junk = '' AND http_title != ''"
    # Bounded: one pass on two threads with a memory ceiling, sorted on disk if needed.
    assert sql =~ "max_threads = 2"
    assert sql =~ "max_memory_usage = 2500000000"
    assert sql =~ "max_bytes_before_external_sort"
    # One version per company: duplicates took candidate slots on the harness.
    assert sql =~ "FROM businesses FINAL"
  end

  test "migration 031's first fill is the same statement as the daily build" do
    [_, fill] = String.split(@migration, "INSERT INTO ls.similar_pool\n", parts: 2)
    body = fn s -> s |> String.replace(~r/\s+/, " ") |> String.trim() |> String.trim_trailing(";") end
    [_, build] = String.split(SimilarPool.build_sql("x"), "INSERT INTO x\n", parts: 2)
    assert body.(fill) == body.(build)
  end

  test "a ranked target reads the nearest candidates, the better-ranked ones first" do
    sql = SimilarPool.read_sql("SaaS", "US", ["$1M-$10M"], 50_000, 10)
    assert sql =~ "FROM similar_pool"
    assert sql =~ "WHERE business_model = 'SaaS'"
    assert sql =~ "AND country = 'US'"
    assert sql =~ "AND revenue IN ('$1M-$10M')"
    assert sql =~ "ORDER BY kind = 'ranked' DESC, rank <= 50000 DESC, abs(toInt64(rank) - 50000) ASC"
    assert sql =~ "LIMIT 10"
  end

  test "an unranked target reads the most recently compiled peers, then the ranked ones" do
    for rank <- [nil, 0, -1, "x"] do
      sql = SimilarPool.read_sql("Agency", "DE", ["<$1M"], rank, 6)
      assert sql =~ "ORDER BY kind = 'recent' DESC, compiled_at DESC, rank ASC", "rank #{inspect(rank)}"
    end
  end

  test "model, country and tier are escaped: a quote in the input cannot leave the string" do
    sql = SimilarPool.read_sql("Sa'aS", "U'S", ["$1M' OR 1=1 --"], nil, 6)
    refute sql =~ "Sa'aS"
    refute sql =~ "'U'S'"
    refute sql =~ "'$1M' OR 1=1 --'"
  end

  test "the daily build is at 11:50 UTC, after the 11:30 optimize, never under a minute away" do
    assert SimilarPool.delay_to_build_ms(~U[2026-10-28 11:00:00Z]) == :timer.minutes(50)
    assert SimilarPool.delay_to_build_ms(~U[2026-10-28 11:49:30Z]) == :timer.hours(24) + 30_000
    assert SimilarPool.delay_to_build_ms(~U[2026-10-28 12:00:00Z]) == :timer.hours(24) - :timer.minutes(10)
    assert SimilarPool.delay_to_build_ms(~U[2026-10-28 11:00:00Z]) > SimilarPool.delay_to_build_ms(~U[2026-10-28 11:30:00Z]) + :timer.minutes(19)
  end

  test "the page reads the pool when it is ready and keeps the scan as its fallback" do
    [_, fun] = String.split(@clickhouse, "def similar_stores(business_model, country, exclude_domain, revenue, rank, limit)", parts: 2)
    fun = String.slice(fun, 0, 3000)
    assert fun =~ "if LS.SimilarPool.ready?() do"
    assert fun =~ "LS.SimilarPool.read_sql(business_model, country, tier, rank, limit + 4)"
    assert fun =~ "FROM businesses", "the scan stays for a box without the pool"
  end

  test "ready? believes a cached answer: yes for good, no for ten minutes, so pages do not probe" do
    :persistent_term.put({SimilarPool, :ready}, true)
    assert SimilarPool.ready?() == true
    :persistent_term.put({SimilarPool, :ready}, {false, System.monotonic_time(:millisecond)})
    assert SimilarPool.ready?() == false
    # A stale no is asked again; without a reachable pool it stays no and is re-dated.
    :persistent_term.put({SimilarPool, :ready}, {false, System.monotonic_time(:millisecond) - :timer.minutes(11)})
    assert is_boolean(SimilarPool.ready?())
  after
    :persistent_term.erase({SimilarPool, :ready})
  end
end
