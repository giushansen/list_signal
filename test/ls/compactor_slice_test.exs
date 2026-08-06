defmodule LS.CompactorSliceTest do
  @moduledoc """
  2026-08-05: compaction died in a spiral — the catch-up window was "everything
  since the last success", so one timeout guaranteed every retry a bigger
  batch, and `businesses` went 19 hours stale while the raw data kept flowing.
  The rule that prevents it: a pass's window is BOUNDED, no matter how long
  the compactor has been failing.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.Compactor

  test "a pass's window never exceeds the slice, however far behind" do
    now = 1_800_000_000

    # 19 hours behind — the real incident. Window must still be one slice.
    since = now - 19 * 3600
    assert Compactor.slice_until(since, now) - since == 1_800

    # A week behind (post-incident cold start) — still one slice.
    assert Compactor.slice_until(now - 7 * 86_400, now) - (now - 7 * 86_400) == 1_800
  end

  test "a caught-up compactor stops at now, not in the future" do
    now = 1_800_000_000
    assert Compactor.slice_until(now - 60, now) == now
  end

  test "the depth join must never read failed enrichment rows" do
    # A failed attempt is a fact about the CRAWL, not about the business.
    # Without this filter the newest row wins even when it is a failed one,
    # and every WAF-blocked recrawl of a previously-enriched business blanks
    # its catalogue, SEO and jobs. Found 2026-08-06, three weeks before the
    # first 30-day re-enrichment wave would have made it real at ~30% of all
    # recrawls. This is a tripwire on the generated SQL: if the filter is
    # ever dropped, this fails before production data does.
    sql = LS.Clickhouse.compact_sql_for_test(0)
    assert sql =~ "render_engine != 'failed'"

    scoped = LS.Clickhouse.compact_sql_for_test(1_700_000_000)
    assert scoped =~ "render_engine != 'failed'"
  end

  test "depth columns merge per-column, never whole-row" do
    # NULL means "could not look" (a sub-fetch failed inside an otherwise
    # successful crawl); 0 means "looked, found none". Whole-row replacement
    # cannot honour that distinction: a crawl whose ATS API call failed would
    # blank job_count for a business whose jobs we counted last month. Every
    # Nullable numeric must merge with argMaxIf(col, ts, col IS NOT NULL).
    sql = LS.Clickhouse.compact_sql_for_test(1_700_000_000)

    for column <- ~w(product_count job_count seo_score price_avg perf_lcp_ms) do
      assert sql =~ "argMaxIf(#{column}, enriched_at, #{column} IS NOT NULL)",
             "#{column} is not NULL-protected — a blind sub-fetch can erase it"
    end
  end
end
