defmodule LS.PipelineRefreshSecondaryTest do
  @moduledoc """
  2026-10-23, six workers: a refreshed domain costs the node budget one
  robots.txt request, one homepage and, for the fifth that has one, up to
  two secondary fetches. An unchanged homepage keeps its secondary pages.
  These pin the decision, the simhash riding along from the due list, and
  that anything unknown still refetches.
  """
  use ExUnit.Case, async: true

  alias LS.Pipeline

  test "an unchanged homepage (same simhash) skips the login and pricing pages" do
    refute Pipeline.refetch_secondary?(123_456_789, 123_456_789)
  end

  test "a near-duplicate within Hamming distance 3 is unchanged, beyond it is a change" do
    base = 0b1010_1010_1010_1010
    refute Pipeline.refetch_secondary?(base, Bitwise.bxor(base, 0b111))
    assert Pipeline.refetch_secondary?(base, Bitwise.bxor(base, 0b1111))
  end

  test "no stored hash, a zero hash, or a first contact refetches: the rule can only save work" do
    assert Pipeline.refetch_secondary?(nil, 42)
    assert Pipeline.refetch_secondary?(0, 42)
    assert Pipeline.refetch_secondary?(42, 0)
    assert Pipeline.refetch_secondary?(42, nil)
    assert Pipeline.refetch_secondary?("42", 42)
  end

  test "the due list carries the stored simhash so the worker needs no second query" do
    sql = LS.Clickhouse.stale_domains_sql(10)
    assert sql =~ "SELECT domain, tier, http_body_simhash FROM ("
    assert sql =~ "http_last_checked_at, http_body_simhash"
  end

  test "Pipeline.http/3 accepts the stored simhash as an option and still works without it" do
    assert function_exported?(Pipeline, :http, 3)
    assert %{http_error: "no_ip"} = Pipeline.http("no-such-host.invalid", nil, prev_simhash: 7)
  end
end
