defmodule LS.Crawl.RenewalsSkipWhatWeDoNotSellTest do
  @moduledoc """
  2026-11-07, one day of fetches (2026-11-06, 241,566 rows) grouped by
  what the previous visit had found: 11,868 domains last read in another
  language gave 15 newly sellable businesses, 5,396 junk pages gave 29,
  while an ICP business gave 129 to 163 in 1,000. They came back on every
  certificate renewal (45 to 64 days) because only tier B and C sat in a
  slow ring. Junk now goes into the 90-100 day ring and other languages
  into the 180-200 day ring. A page with no language must never be
  placed: those are the DNS-only rows of August and September, the best
  fetches of the day (46 in 1,000).
  """
  use ExUnit.Case, async: true

  alias LS.Crawl.Tiers

  test "junk goes to the B ring, another language to the C ring, no language and EN/FR nowhere" do
    sql = Tiers.slow_ring_sql()
    assert sql =~ "estimated_junk != '', 'b'"
    assert sql =~ "http_language != '' AND NOT #{LS.Crawl.Markets.refresh_language_sql()}, 'c'"
    assert String.ends_with?(sql, ", '')")
  end

  test "the compaction query reads one window and returns only placed rows" do
    sql = Tiers.compiled_slow_sql(1_700_000_000, 1_700_003_600)
    assert sql =~ "compiled_at >= toDateTime(1700000000) AND compiled_at < toDateTime(1700003600)"
    assert sql =~ "WHERE ring != ''"
    assert sql =~ "max_execution_time = 60"
  end

  test "the backfill takes only the two slow rings and well-formed bounds" do
    sql = Tiers.slow_backfill_sql("c", 1_700_000_000, nil, 3, 8)
    assert sql =~ "= 'c'"
    assert sql =~ "cityHash64(domain) % 8 = 3"
    refute sql =~ "http_last_checked_at < toDateTime("
    assert Tiers.slow_backfill_sql("b", 1, 2, 0, 8) =~ "http_last_checked_at < toDateTime(2)"

    for bad <- ["a", "c' OR 1=1 --", nil, :c] do
      assert_raise FunctionClauseError, fn -> Tiers.slow_backfill_sql(bad, 1, nil, 0, 8) end
    end

    assert_raise FunctionClauseError, fn -> Tiers.slow_backfill_sql("c", 1, nil, 8, 8) end
    assert_raise FunctionClauseError, fn -> Tiers.slow_backfill_sql("c", "1", nil, 0, 8) end
  end

  test "the compactor marks the slow rings every pass, without marking them known" do
    src = File.read!("lib/ls/cluster/compactor.ex")
    assert src =~ "mark_slow(s.since - @lookback_slack_s, until)"
    [_, body] = String.split(src, "def mark_slow(since, until) do", parts: 2)
    [body | _] = String.split(body, "\n  def ", parts: 2)
    refute body =~ "mark_known"
  end

  test "a business in the C ring is skipped when its certificate is renewed" do
    case GenServer.whereis(LS.Cluster.WorkQueue) do
      nil -> {:ok, _} = LS.Cluster.WorkQueue.start_link()
      _ -> :ok
    end

    assert :persistent_term.get({LS.Cluster.CrawlDedup, :tier_c}, nil), "the tier C ring is loaded in the test app"
    domain = "otherlang-#{System.unique_integer([:positive])}.test"
    assert LS.Cluster.CrawlDedup.mark_tier_c([domain]) == 1
    assert LS.Cluster.WorkQueue.enqueue(%{ctl_domain: domain, source: :ctl}, []) == :recently_crawled
  end
end
