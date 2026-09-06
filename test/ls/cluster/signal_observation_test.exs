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

  test "the predicate reads the stored flag, never the 500-byte snippet (compaction stayed under its ceiling)" do
    sql = LS.Clickhouse.observed_sql()
    assert sql == "(http_status BETWEEN 200 AND 399 AND http_observed = 1)"
    refute sql =~ "http_body_snippet"
    assert LS.Clickhouse.observed_sql("s_") == "(s_http_status BETWEEN 200 AND 399 AND s_http_observed = 1)"
  end

  describe "LS.Pipeline.observed?/1 is the rule, computed once at insert time" do
    test "a real page is observed" do
      assert LS.Pipeline.observed?(%{http_status: 200, http_blocked: "", _body_text: String.duplicate("word ", 60), http_title: "Acme Inc"}) == 1
    end

    test "the stub signatures the sample found are not" do
      base = %{http_status: 200, http_blocked: "", _body_text: String.duplicate("word ", 60), http_title: "Acme"}
      assert LS.Pipeline.observed?(%{base | _body_text: "checking your browser"}) == 0
      assert LS.Pipeline.observed?(%{base | http_title: "Just a moment..."}) == 0
      assert LS.Pipeline.observed?(%{base | http_title: "Index of /"}) == 0
      assert LS.Pipeline.observed?(%{base | http_title: "Redirecting..."}) == 0
      assert LS.Pipeline.observed?(%{base | http_blocked: "cloudflare"}) == 0
      assert LS.Pipeline.observed?(%{base | http_status: 403}) == 0
      assert LS.Pipeline.observed?(%{base | http_status: nil}) == 0
    end

    test "hostile input is unobserved, never a crash" do
      assert LS.Pipeline.observed?(nil) == 0
      assert LS.Pipeline.observed?(%{http_status: 200, _body_text: <<255, 0>>, http_title: 42}) in [0, 1]
      assert LS.Pipeline.observed?(%{http_status: "200"}) == 0
    end

    test "a row from a worker that predates the flag is observed when its fetch succeeded" do
      # Rolling deploy, 2026-09-06: for the hour in which workers ran the old
      # release, every row arrived without the key and was written as 0.
      src = File.read!("lib/ls/cluster/inserter.ex")
      assert src =~ "Map.put_new(&1, :http_observed, if(is_integer(&1[:http_status]) and &1[:http_status] in 200..399, do: 1, else: 0))"
    end

    test "every discovery row carries the flag" do
      assert :http_observed in LS.Cluster.Inserter.columns()
      assert File.read!("lib/ls/pipeline.ex") =~ "http_observed: observed?(http),"
    end
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
    assert @src =~ "http_observed AS s_http_observed"
  end
end
