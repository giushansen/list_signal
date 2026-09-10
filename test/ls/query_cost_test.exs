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

    # 2026-09-10: the 30-day NOT IN set (14M domains, 1.8 GiB) plus a sort of
    # the wide row needed 4.6 GiB and the server refused it on every run for
    # two days; pipeline 2 fell to a fifth. The narrow inner select reads the
    # compiled depth_enriched_at for "done in the last 30 days" and keeps a
    # 7-day NOT IN for failed attempts and compaction lag (1.9s, 534 MB).
    assert fun =~ "NOT IN (SELECT domain FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 7 DAY)"
    refute fun =~ "biz_enrichment WHERE enriched_at >= now() - INTERVAL 30 DAY", "the 30-day set is what could not fit in memory"
    assert fun =~ "depth_enriched_at IS NULL OR i.depth_enriched_at < now() - INTERVAL 30 DAY"
    assert fun =~ "WHERE b.domain IN (", "the wide columns must be read for the chosen domains only"
    assert fun =~ "max_memory_usage = 2500000000", "fail this query, never the server"

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
    # The tech readers moved to LS.Clickhouse.Tech on 2026-09-09.
    src = File.read!("lib/ls/clickhouse/tech.ex")

    for f <- ~w(tech_language_distribution tech_hosting_distribution
                tech_registrar_distribution tech_co_occurring tech_stats) do
      body = src |> String.split("def #{f}(tech_name) do") |> Enum.at(1) |> String.slice(0, 400)
      assert body =~ "LandingCache.cached", "#{f} is uncached and scans domains_fast in full"
    end
  end
end
