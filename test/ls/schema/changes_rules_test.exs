defmodule LS.Schema.ChangesRulesTest do
  @moduledoc """
  `changes_log` detection is generated from the column spec (2026-10-01).
  These pin the SQL each rule produces, the guards that keep first fills and
  blind spots from reading as changes, and the one-time import of the v1
  `biz_signal` rows.
  """
  use ExUnit.Case, async: true

  alias LS.Schema.Changes

  test "a set rule emits added and removed only when both sides are non-empty" do
    sql = Changes.rule_sql({"http_tech", :set, "Array(LowCardinality(String))"})
    assert sql =~ "notEmpty(n.http_tech) AND notEmpty(o.http_tech)"
    assert sql =~ "('http_tech', 'added', toString(x), '', n.http_last_checked_at)"
    assert sql =~ "('http_tech', 'removed', toString(x), '', n.http_last_checked_at)"
    assert sql =~ "arrayFilter(x -> NOT has(o.http_tech, x), n.http_tech)"
  end

  test "a set_added rule never emits removals" do
    sql = Changes.rule_sql({"http_emails", :set_added, "Array(String)"})
    assert sql =~ "'added'"
    refute sql =~ "'removed'"
  end

  test "a string changed rule ignores empty on either side" do
    sql = Changes.rule_sql({"estimated_revenue", :changed, "LowCardinality(String)"})
    assert sql =~ "n.estimated_revenue != o.estimated_revenue AND o.estimated_revenue != '' AND n.estimated_revenue != ''"
  end

  test "a numeric changed rule ignores NULL on either side" do
    sql = Changes.rule_sql({"shop_plus", :changed, "Nullable(UInt8)"})
    assert sql =~ "n.shop_plus IS NOT NULL AND o.shop_plus IS NOT NULL AND n.shop_plus != o.shop_plus"
  end

  test "hiring starts when jobs go from none to some and stops only on a measured zero" do
    sql = Changes.rule_sql({"hr_job_count", :started_stopped, "Nullable(UInt16)"})
    assert sql =~ "coalesce(o.hr_job_count, 0) = 0 AND coalesce(n.hr_job_count, 0) > 0"
    assert sql =~ "coalesce(o.hr_job_count, 0) > 0 AND n.hr_job_count = 0"
    # deep-pass fields are stamped with the deep pass time
    assert sql =~ "ifNull(n.http_deep_last_seen_at, n.http_last_checked_at)"
  end

  test "a website is down when a 2xx becomes a measured non-2xx, never when the fetch did not happen" do
    sql = Changes.rule_sql({"http_status", :down_back, "Nullable(Int32)"})
    assert sql =~ "(o.http_status BETWEEN 200 AND 399) AND n.http_status IS NOT NULL AND NOT (n.http_status BETWEEN 200 AND 399)"
    assert sql =~ "'back'"
  end

  test "a percentage rule needs a measured old value above zero" do
    sql = Changes.rule_sql({"shop_product_count", {:pct, 0.2}, "Nullable(UInt32)"})
    assert sql =~ "o.shop_product_count > 0 AND n.shop_product_count IS NOT NULL"
    assert sql =~ ">= 0.2"
  end

  test "the detection statement joins scratch to the newest current row and covers every tracked column" do
    sql = Changes.detect_sql("tmp_x")
    assert sql =~ "INSERT INTO changes_log (domain, field, change, value, prev_value, changed_at)"
    assert sql =~ "FROM tmp_x AS n"
    assert sql =~ "INNER JOIN"
    assert sql =~ ~r/ORDER BY compiled_at DESC\s+LIMIT 1 BY domain/

    for {name, _, _} <- LS.Schema.Columns.tracked() do
      assert sql =~ "'#{name}'", "detection misses #{name}"
    end
  end

  test "the v1 import maps tech and app events to http_tech and hiring events to hr_job_count" do
    sql = Changes.import_v1_sql()
    assert sql =~ "if(kind IN ('tech_added', 'tech_removed', 'app_added', 'app_removed'), 'http_tech', 'hr_job_count')"
    assert sql =~ "kind = 'started_hiring', 'started', 'stopped'"
    assert sql =~ "transform(value"
    assert sql =~ "FROM biz_signal"
  end

  test "changes_log is keyed for 'who added X last week' and has a per-domain projection" do
    ddl = Changes.ddl()
    assert ddl =~ "ORDER BY (field, value, changed_at, domain)"
    assert ddl =~ "PROJECTION by_domain (SELECT * ORDER BY domain, changed_at)"
    assert ddl =~ "deduplicate_merge_projection_mode = 'rebuild'"
  end

  test "the page store keeps the latest version per domain and page kind, text compressed with ZSTD" do
    ddl = Changes.pages_ddl()
    assert ddl =~ "ReplacingMergeTree(http_fetched_at)"
    assert ddl =~ "ORDER BY (domain, page_kind)"
    assert ddl =~ "`http_body_texts` Array(String) CODEC(ZSTD(3))"
  end
end
