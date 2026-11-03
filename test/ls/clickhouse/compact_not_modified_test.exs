defmodule LS.Clickhouse.CompactNotModifiedTest do
  @moduledoc """
  2026-11-03, conditional GET: a 304 row carries no page. The fold must
  count it as a live check (last_verified_at, crawlable) and must not let
  it replace the status, the wall, the timing or the junk verdict of the
  last full read, or every unchanged site would read as status 304 with
  no junk verdict after its first refresh.
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse.Compact

  test "the page-status predicate excludes 304 and keeps the 2xx/3xx band" do
    assert Compact.page_status_sql("s_") == "(s_http_status BETWEEN 200 AND 399 AND s_http_status != 304)"
    assert Compact.page_status_sql() =~ "http_status != 304"
  end

  test "status, timing, wall and content type fold through the page-status predicate" do
    sql = Compact.compact_sql_for_test(0, 1)

    for col <- ~w(s_http_status s_http_response_time s_http_blocked s_http_content_type) do
      assert sql =~ "argMaxIf(#{col}, s_enriched_at, (s_http_status BETWEEN 200 AND 399 AND s_http_status != 304))", col
    end
  end

  test "the junk fold keeps its 2026-09 shape and a 304 row cannot change the verdict" do
    # The fold still reads the 304 row; the worker writes '' there
    # (LS.Pipeline.merge_row) and only estimated_junk = '' businesses are
    # refreshed with validators, so the verdict stays ''.
    sql = Compact.compact_sql_for_test(0, 1)
    assert sql =~ "argMaxIf(s_is_junk, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS is_junk"
    assert File.read!("lib/ls/pipeline.ex") =~ ~s|is_junk = if http[:_not_modified], do: "", else: BusinessClassifier.junk_reason(classify_signals)|
    assert LS.Clickhouse.stale_domains_sql(1) =~ "estimated_junk = ''"
  end

  test "a 304 still proves the site alive" do
    sql = Compact.compact_sql_for_test(0, 1)
    assert sql =~ "maxIf(s_enriched_at, s_http_status BETWEEN 200 AND 399) AS last_verified_at"
    assert sql =~ "max(s_http_status BETWEEN 200 AND 399) AS crawlable"
  end

  test "the refresh item carries the validators when the last read had them" do
    src = File.read!("lib/ls/recrawl/scheduler.ex")
    assert src =~ "LS.Clickhouse.validators("
    sql = File.read!("lib/ls/clickhouse.ex")
    assert sql =~ "http_status = 200 AND (http_etag != '' OR http_last_modified != '')"
  end
end
