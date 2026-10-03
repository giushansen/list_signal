defmodule LS.Crawl.TiersTest do
  use ExUnit.Case, async: true

  alias LS.Crawl.Tiers

  @moduledoc """
  2026-10-03: refreshes were whatever CT re-emitted after the 7-day ring,
  about a month for every business, and a flat two weeks for all 14.6M ICP
  sites would have cost 2.8 times the refresh budget (1.04M fetches a day
  against 367K). Three tiers by what a customer buys: A 14 days, B 60,
  C 120. The Elixir and SQL forms must agree, so the same cases drive both.
  """

  @cases [
    {%{estimated_business_model: "SaaS", estimated_revenue: "$1M-$10M"}, :a},
    {%{estimated_business_model: "Ecommerce", shop_product_count: 120}, :a},
    {%{estimated_business_model: "Agency", hr_job_count: 3}, :a},
    {%{estimated_business_model: "Consulting", http_emails: ["a@b.example"]}, :a},
    {%{estimated_business_model: "Tool", http_phone: "+33 1 23"}, :a},
    {%{estimated_business_model: "SaaS", estimated_revenue: "<$1M"}, :b},
    {%{estimated_business_model: ""}, :b},
    {%{estimated_business_model: "LocalBusiness", estimated_revenue: "$10M-$100M"}, :c},
    {%{estimated_business_model: "Media"}, :c},
    {%{estimated_business_model: "SaaS", estimated_revenue: "$1B+", tranco_rank: 500}, :c}
  ]

  test "the Elixir tier of each case" do
    for {row, tier} <- @cases, do: assert(Tiers.tier(row) == tier, inspect(row))
    assert Tiers.tier(%{"estimated_business_model" => "SaaS", "estimated_revenue" => "$1M-$10M"}) == :a
  end

  test "cadences are 14, 60 and 120 days and the top rank goes to C" do
    assert Tiers.cadence_days(:a) == 14
    assert Tiers.cadence_days(:b) == 60
    assert Tiers.cadence_days(:c) == 120
    assert Tiers.tier_sql() =~ "tranco_rank <= 100000, 'c'"
  end

  test "the due query excludes walled sites and robots opt-outs, keeps 429, orders A first and oldest first" do
    sql = LS.Clickhouse.stale_domains_sql(1000)
    assert sql =~ "http_status NOT IN (403, 503)"
    refute sql =~ "429"
    assert sql =~ "http_error != 'robots_disallow'"
    assert sql =~ "http_blocked = ''"
    assert sql =~ "ORDER BY tier ASC, http_last_checked_at ASC"
    assert sql =~ "LIMIT 1000"
    assert sql =~ "multiIf(tier = 'a', 14, tier = 'b', 60, 120) DAY"
  end

  test "the compiled-tiers query reads the pass window and skips junk" do
    sql = Tiers.compiled_tiers_sql(1_700_000_000, 1_700_000_300)
    assert sql =~ "compiled_at >= toDateTime(1700000000) AND compiled_at < toDateTime(1700000300)"
    assert sql =~ "estimated_junk = ''"
  end

  describe "against a ClickHouse harness" do
    defp harness? do
      match?({:ok, _}, LS.Clickhouse.query_raw("SELECT 1", 2_000))
    end

    test "both queries parse and the SQL tier agrees with the Elixir tier" do
      if harness?() do
        assert {:ok, _} = LS.Clickhouse.query_raw("EXPLAIN SYNTAX " <> LS.Clickhouse.stale_domains_sql(10), 10_000)
        assert {:ok, _} = LS.Clickhouse.query_raw("EXPLAIN SYNTAX " <> Tiers.compiled_tiers_sql(0, 1), 10_000)

        for {row, tier} <- @cases do
          literal = fn v ->
            cond do
              is_nil(v) -> "NULL"
              is_list(v) -> "[" <> Enum.map_join(v, ",", &"'#{&1}'") <> "]"
              is_integer(v) -> Integer.to_string(v)
              true -> "'#{v}'"
            end
          end

          sql =
            "SELECT #{Tiers.tier_sql()} FROM (SELECT " <>
              "#{literal.(Map.get(row, :tranco_rank))} AS tranco_rank, " <>
              "'#{Map.get(row, :estimated_business_model, "")}' AS estimated_business_model, " <>
              "'#{Map.get(row, :estimated_revenue, "")}' AS estimated_revenue, " <>
              "#{literal.(Map.get(row, :hr_job_count))} AS hr_job_count, " <>
              "#{literal.(Map.get(row, :shop_product_count))} AS shop_product_count, " <>
              "#{literal.(Map.get(row, :http_emails, []))} AS http_emails, " <>
              "'#{Map.get(row, :http_phone, "")}' AS http_phone)"

          assert {:ok, [[got]]} = LS.Clickhouse.query_raw(sql, 10_000)
          assert got == Atom.to_string(tier), "#{inspect(row)}: SQL said #{got}"
        end
      else
        IO.puts("\n[tiers] no ClickHouse harness, SQL agreement not checked")
      end
    end
  end
end
