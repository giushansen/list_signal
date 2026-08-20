defmodule LS.Verification.StoreTest do
  @moduledoc "Pure parts of the store + the SQL tripwires that keep pipeline 3 honest in the compactor and the explorer."
  use ExUnit.Case, async: true
  alias LS.Verification.Store

  @ts ~N[2026-08-18 12:00:00]

  test "record_row/2 sanitises hostile source values before they reach ClickHouse" do
    r = %{source: :wikidata, source_id: "Q1", name: "Acme\x00 \x07Ltd" <> String.duplicate("x", 2000),
          website: "https://acme.com", revenue_usd: -5, employees: -1, revenue_raw: nil, employees_band: nil, extra: %{"industry" => "x"}}
    row = Store.record_row(r, @ts)
    refute row.name =~ "\x00"
    assert String.length(row.name) <= 500
    assert row.revenue_usd == nil, "negative revenue is not a fact"
    assert row.employees == nil
    assert row.website_domain == "acme.com"
    assert row.matched_domain == ""
    assert row.name_key == "acme" <> String.duplicate("x", 496) or String.starts_with?(row.name_key, "acme")
  end

  test "facts_for/2 emits one fact per populated field, all keyed to the matched domain" do
    row = Store.record_row(%{source: :yc, source_id: "doordash", name: "DoorDash", website: "http://doordash.com",
                             employees: 8600, extra: %{"mission" => "Restaurant delivery.", "industry" => "Consumer"},
                             matched_domain: "doordash.com", match_method: "website", source_url: "u"}, @ts)
    facts = Store.facts_for(row, @ts)
    assert Enum.map(facts, & &1.fact) |> Enum.sort() == ["employees", "industry", "mission"]
    assert Enum.all?(facts, &(&1.domain == "doordash.com" and &1.match_method == "website" and &1.source == "yc"))
  end

  test "content_hash changes with content and with the link, not with fetched_at (unchanged business → no row)" do
    r = %{source: :yc, source_id: "x", name: "X", website: "https://x.com", employees: 3}
    a = Store.record_row(r, @ts)
    b = Store.record_row(r, ~N[2026-09-18 12:00:00])
    assert a.content_hash == b.content_hash
    assert String.length(a.content_hash) == 16
    changed = Store.record_row(%{r | employees: 4}, @ts)
    assert changed.content_hash != a.content_hash
    linked = Store.record_row(Map.merge(r, %{matched_domain: "x.com", match_method: "website"}), @ts)
    assert linked.content_hash != a.content_hash, "a newly linked record must count as changed"
  end

  test "an unmatched record contributes no facts" do
    row = Store.record_row(%{source: :yc, source_id: "x", name: "X", website: "https://x.com", employees: 3}, @ts)
    assert Store.facts_for(row, @ts) == []
  end

  describe "SQL tripwires" do
    test "the compactor folds verified_* by source precedence, never by recency" do
      sql = LS.Clickhouse.verified_sql("")
      assert sql =~ "argMinIf(rev_bracket, rev_prio"
      assert sql =~ "source = 'sec_edgar', 1"
      assert sql =~ "source = 'wikidata', 4"
      assert sql =~ "source = 'wikidata', 1"
      assert sql =~ "source = 'yc', 4"
      compact = LS.Clickhouse.compact_sql_for_test(1_700_000_000)
      assert compact =~ "verified_revenue, verified_revenue_source, verified_employees, verified_employees_source, mission_summary"
      assert compact =~ "SELECT domain FROM verified_facts WHERE fetched_at >="
      refute compact =~ "estimated_revenue = v.", "estimated_* must never be written by pipeline 3"
    end

    test "the sharded rebuild guards the verified_facts side too (unscoped FINAL = memory bomb)" do
      full = LS.Clickhouse.compact_sql_for_test(0)
      assert full =~ "FROM verified_facts\n"
      # Newest fact per (domain, fact, source) via LIMIT 1 BY — NOT an inner
      # aggregate the outer argMaxIf also reads (nested-aggregate Code 184
      # silently failed every compaction and froze `businesses` 12h, 2026-08-19).
      assert full =~ "LIMIT 1 BY domain, fact, source"
      refute full =~ "max(fetched_at) AS fetched_at", "nested aggregate reintroduced — this froze the compactor once"
    end

    test "explorer revenue/employees filters match the SHOWN value" do
      assert LS.Explorer.shown_revenue_sql() == "if(verified_revenue != '', verified_revenue, estimated_revenue)"
      assert LS.Explorer.shown_employees_sql() == "if(verified_employees != '', verified_employees, estimated_employees)"
    end
  end
end
