defmodule LS.QueryCostTest do
  @moduledoc """
  2026-08-24 capacity audit: ClickHouse demanded 6.7 cores on a 4-core box,
  93% of it reads. These are the source-level guards on the three worst
  offenders, so a future edit cannot quietly reintroduce them.
  """
  use ExUnit.Case, async: true

  # Read at RUNTIME, not into a module attribute: a @attr File.read! is
  # evaluated when the test module compiles, so it silently keeps stale source
  # after the file under guard changes.
  defp ch, do: File.read!("lib/ls/clickhouse.ex")

  test "the enrichment refill uses a semi-join and a background-sized timeout" do
    fun = ch() |> String.split("def businesses_needing_enrichment") |> Enum.at(1) |> String.slice(0, 6000)

    refute fun =~ "LEFT JOIN biz_enrichment",
           "a JOIN costs ~9x a single-table scan here; the semi-join is the same set at 8.2s vs 13.1s"

    assert fun =~ "NOT IN (SELECT domain FROM biz_enrichment"

    # As a WHERE predicate, not merely named in the comment explaining why.
    refute fun =~ ~r/\bb\.depth_enriched_at\b/,
           "depth_enriched_at is NULL for ~2.3M already-enriched domains — filtering on it re-crawls them"

    assert fun =~ "query_raw(sql, 90_000)",
           "the 25s default expired mid-scan and starved the enrichment nodes"
  end

  test "similar_stores caches on coarse rank bands, not a fine-grained bucket" do
    fun = ch() |> String.split("def similar_stores(business_model, country, exclude_domain, revenue, rank, limit)") |> Enum.at(1) |> String.slice(0, 2500)

    refute fun =~ "div(r, 20_000)",
           "the fine bucket gave nearly every store page its own cache key (71 buckets / 129 entries)"

    for band <- [":top100k", ":top1m", ":rest"], do: assert(fun =~ band)
  end

  test "every per-tech distribution is cached — each one full-scans 153.7M rows" do
    src = ch()

    for f <- ~w(tech_language_distribution tech_hosting_distribution
                tech_registrar_distribution tech_co_occurring tech_stats) do
      body = src |> String.split("def #{f}(tech_name) do") |> Enum.at(1) |> String.slice(0, 400)
      assert body =~ "LandingCache.cached", "#{f} is uncached and scans domains_fast in full"
    end
  end
end
