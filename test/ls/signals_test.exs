defmodule LS.SignalsTest do
  @moduledoc """
  The Signals tab and `/api/v1/changes` read `changes_log` through
  `LS.Signals` (2026-10-01). These pin the two query shapes, the allow-list
  that keeps query params out of the key columns, and the export's shape.
  """
  use ExUnit.Case, async: true

  alias LS.Signals

  test "with no business filter the log is paged first and businesses joined for the page only" do
    sql = Signals.list_sql(%{period: "7d"}, per_page: 50, page: 2)
    assert sql =~ "WITH page AS ("
    assert sql =~ "changed_at >= now() - INTERVAL 7 DAY"
    assert sql =~ "LIMIT 50 OFFSET 50"
    assert sql =~ "WHERE domain IN (SELECT domain FROM page)"
    refute sql =~ "INNER JOIN"
  end

  test "a country or model filter joins first, then pages" do
    sql = Signals.list_sql(%{period: "30d", country: "fr,de", business_model: "SaaS"})
    assert sql =~ "INNER JOIN"
    assert sql =~ "estimated_country IN ('FR', 'DE')"
    assert sql =~ "estimated_business_model IN ('SaaS')"
    assert sql =~ "changed_at >= now() - INTERVAL 30 DAY"
  end

  test "field and change only accept known values; an unknown one matches nothing rather than reaching SQL" do
    sql = Signals.list_sql(%{field: "http_tech,drop table", change: "added"})
    assert sql =~ "field IN ('http_tech')"
    assert sql =~ "change IN ('added')"

    sql = Signals.list_sql(%{field: "nonsense"})
    assert sql =~ "1 = 0"
    refute sql =~ "nonsense"
  end

  test "value and domain are escaped and exact or substring respectively" do
    sql = Signals.list_sql(%{value: "Klav'iyo", domain_search: "Shop.Example"})
    assert sql =~ "value = 'Klav\\'iyo'" or sql =~ "value = 'Klaviyo'"
    assert sql =~ "domain LIKE '%shop.example%'"
  end

  test "an unknown period falls back to 7 days, the default the UI shows" do
    assert Signals.list_sql(%{period: "forever"}) =~ "INTERVAL 7 DAY"
    assert Signals.default_filters().period == "7d"
  end

  test "the count query mirrors the two shapes" do
    assert Signals.count_sql(%{}) =~ "SELECT count() FROM changes_log WHERE changed_at"
    assert Signals.count_sql(%{country: "US"}) =~ "estimated_country IN ('US')"
  end

  test "fields offered are the tracked columns and the export adds a summary column" do
    assert Signals.fields() == Enum.map(LS.Schema.Columns.tracked(), &elem(&1, 0))
    assert List.last(Signals.export_columns()) == "summary"
    assert "changed_at" in Signals.export_columns()
  end

  test "change sentences read as a person would say them" do
    alias LSWeb.ExplorerLive.Format
    assert Format.change_sentence("http_tech", "added", "Klaviyo", "") == "Klaviyo added"
    assert Format.change_sentence("http_tech", "removed", "Yoast SEO", "") == "Yoast SEO removed"
    assert Format.change_sentence("estimated_revenue", "changed", "$10M-$100M", "$1M-$10M") == "from $1M-$10M to $10M-$100M"
    assert Format.change_sentence("hr_job_count", "started", "12", "0") == "started hiring (12 roles)"
    assert Format.change_sentence("hr_job_count", "started", "1", "0") == "started hiring (1 role)"
    assert Format.change_sentence("hr_job_count", "stopped", "0", "4") == "stopped hiring (was 4)"
    assert Format.change_sentence("http_status", "down", "503", "200") == "website down (503)"
    assert Format.change_sentence("shop_plus", "changed", "1", "0") == "upgraded to Shopify Plus"
    assert Format.change_tone("added") == :up
    assert Format.change_tone("removed") == :down
  end
end
