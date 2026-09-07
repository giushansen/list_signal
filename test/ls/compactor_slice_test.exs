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
  # 2026-09-07: every five-minute pass read the WHOLE domains_history table
  # (378M rows, 80 GB) because `domain IN (touched)` on a table ordered by
  # domain, with ~20K touched domains spread over 47K granules, prunes
  # nothing. Passes took 190-570 s, crossed every ceiling (290, 590, 1190 s)
  # and two a day died on ClickHouse's memory cap; "Ingestion rate: new
  # businesses" emailed the owner three times in two days while the raw
  # data kept flowing. The pass now folds the window's rows into the
  # compiled row. These pin the shape of that query.
  describe "an incremental pass reads the window, not the touched domains' whole history" do
    @since 1_700_000_000
    @until 1_700_000_300

    test "the history read is bounded by the window, never by the touched set" do
      sql = LS.Clickhouse.compact_sql_for_test(@since, @until)

      refute sql =~ "FROM domains_history WHERE domain IN (SELECT arrayJoin(_touched))",
             "the touched-set read is back: that is the 80 GB full scan"

      assert sql =~ "FROM domains_history WHERE enriched_at >= toDateTime(#{@since}) AND enriched_at < toDateTime(#{@until})"
    end

    test "only new candidates get their older history, and only the older part of it" do
      sql = LS.Clickhouse.compact_sql_for_test(@since, @until)

      assert sql =~ "FROM domains_history WHERE domain IN (SELECT arrayJoin(_candidates)) AND enriched_at < toDateTime(#{@since})"
      # Candidates are window domains with no compiled row that could
      # qualify one. Anything else folds from its window rows alone.
      assert sql =~ "AND domain NOT IN (SELECT domain FROM businesses\n"
      refute sql =~ "NOT IN (SELECT domain FROM businesses)", "unscoped NOT IN is a 3.3 GB hash set"
      assert sql =~ "(business_model != '' OR http_blocked != '' OR http_status IN (401, 403, 429))"
    end

    test "existing rows enter the fold as two synthetic history rows from one read" do
      sql = LS.Clickhouse.compact_sql_for_test(@since, @until)

      # Newest version by as_of, not FINAL: FINAL merged all 18.6M rows per
      # pass (966 s, 7 GB, killed on the server cap, 2026-09-07).
      assert sql =~ "FROM (SELECT * FROM businesses WHERE domain IN (SELECT arrayJoin(_touched)) ORDER BY as_of DESC LIMIT 1 BY domain)\n  ARRAY JOIN if(crawlable = 1, [1, 2], [2]) AS leg"
      refute sql =~ "businesses FINAL"
      # The verified row exists only for crawlable businesses and is the
      # only synthetic row the 2xx rules can pick.
      assert sql =~ "ARRAY JOIN if(crawlable = 1, [1, 2], [2]) AS leg"
      assert sql =~ "if(leg = 1, last_verified_at, as_of) AS s_enriched_at"
      assert sql =~ "if(leg = 1, 1, 0) AS s_http_observed"
      # Both rows must carry the group key. A blanked domain on the
      # verified row dropped 2,082 of 9,633 businesses in one probe pass.
      assert sql =~ "last_worker AS s_worker, domain AS s_domain,"
      refute sql =~ "if(leg = 1, '', domain)"
      assert sql =~ "if(leg = 1, http_title, '') AS s_http_title"
      # The latest row masks a 2xx status so it never competes for them,
      # and carries what a compiled row cannot recover otherwise.
      assert sql =~ "if(leg = 1, http_status, if(last_http_status BETWEEN 200 AND 399, NULL, last_http_status)) AS s_http_status"
      assert sql =~ "if(leg = 1, CAST(NULL, 'Nullable(Int32)'), tranco_rank) AS s_tranco_rank"
      assert sql =~ "first_seen AS s_first_seen, dns_alive AS s_dns_alive"
      assert sql =~ "min(s_first_seen) AS first_seen"
      assert sql =~ "argMax(s_dns_alive, s_enriched_at) AS dns_alive"
    end

    test "the incremental fold never spills its aggregation to disk" do
      # 628 spill files for 36 MB took a 44 s fold to 165 s (2026-09-07).
      # What the tracker counts here is read buffers, not aggregation state.
      assert LS.Clickhouse.compact_sql_for_test(@since, @until) =~ "max_bytes_before_external_group_by = 0,"
      assert LS.Clickhouse.compact_sql_for_test(0) =~ "max_bytes_before_external_group_by = 1500000000,"
    end

    test "a blank on a synthetic row is a typed NULL for Nullable columns, '' otherwise" do
      sql = LS.Clickhouse.compact_sql_for_test(@since, @until)
      # A '' where NULL belongs would read as a measurement to every
      # `IS NOT NULL` rule and overwrite a real value with garbage.
      # http_response_time is a 2xx column: blank on the latest row.
      assert sql =~ "if(leg = 1, http_response_time, CAST(NULL, 'Nullable(Int32)')) AS s_http_response_time"
      # classification_confidence is not: blank on the verified row.
      assert sql =~ "if(leg = 1, CAST(NULL, 'Nullable(Float32)'), classification_confidence) AS s_classification_confidence"
      assert sql =~ "if(leg = 1, CAST(NULL, 'Nullable(DateTime)'), rdap_domain_created_at) AS s_rdap_domain_created_at"
      assert sql =~ "if(leg = 1, '', dns_mx) AS s_dns_mx"
    end

    test "a full rebuild and the shard rebuild still read history whole" do
      full = LS.Clickhouse.compact_sql_for_test(0)
      refute full =~ "UNION ALL"
      refute full =~ "FROM businesses FINAL"
      assert full =~ "FROM domains_history)"

      shard = LS.Clickhouse.compact_sql_shard_preview(3, 256)
      assert shard =~ "FROM domains_history WHERE domain IN (SELECT domain FROM businesses WHERE cityHash64(domain) % 256 = 3))"
    end
  end
end
