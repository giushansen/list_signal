defmodule LS.Cluster.SignalObservationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A change event is only as true as the two crawls it compares (2026-09-06).

  Measured on 2,000 sampled "started showing" and 1,000 "stopped showing"
  events from the last 90 days: 13.3% of additions had a before-crawl that
  was a stub (bot wall served as 200, redirect shell, empty body) and 16.6%
  of removals had an after-crawl of the same kind. Persistence at 8 weeks
  was 78.7-86.7% by kind and 63,863 (domain, technology) pairs flapped 3+
  times. These pins keep every producer of technology state on one
  definition of "observed".
  """

  @src File.read!("lib/ls/clickhouse.ex")

  test "the observation predicate names the stub signatures the sample found" do
    sql = LS.Clickhouse.observed_sql()
    assert sql =~ "http_status BETWEEN 200 AND 399"
    assert sql =~ "http_blocked = ''"
    assert sql =~ "length(http_body_snippet) >= 200"
    for t <- ["just a moment", "bot verification", "redirecting", "attention required", "index of /"] do
      assert sql =~ t
    end
  end

  test "a prefix rewrites every column reference, for the compactor's s_ subselect" do
    sql = LS.Clickhouse.observed_sql("s_")
    assert sql =~ "s_http_status" and sql =~ "s_http_blocked" and sql =~ "s_http_body_snippet" and sql =~ "s_http_title"
    refute sql =~ ~r/[^_]http_status/
  end

  test "record_signals, the backfill and the compactor fold all use it" do
    [signals | _] = String.split(@src, "def record_signals") |> Enum.drop(1)
    [signals | _] = String.split(signals, "def backfill_signals_shard")
    assert signals =~ "AND \#{observed_sql()} AND http_tech != ''"

    [backfill | _] = String.split(@src, "def backfill_signals_shard") |> Enum.drop(1)
    [backfill | _] = String.split(backfill, "\n  end\n")
    assert backfill =~ "\#{observed_sql()}"

    assert @src =~ "argMaxIf(s_http_tech, s_enriched_at, \#{observed_sql(\"s_\")}) AS http_tech"
    assert @src =~ "argMaxIf(s_http_apps, s_enriched_at, \#{observed_sql(\"s_\")}) AS http_apps"
    assert @src =~ "http_body_snippet AS s_http_body_snippet"
  end
end
