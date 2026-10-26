defmodule LS.ApiDataQueryTest do
  @moduledoc """
  2026-10-26, from a reviewer using the connector: no sort, no totals, no
  multi-country, no first-seen filter, no "has a named email", no field
  choice, no aggregation; measuring anything meant one get_company call
  per row. One bounded query tool answers those, and the search default
  moved from traffic order to the product's target ranking.
  """
  use ExUnit.Case, async: true

  alias LS.ApiData

  test "the filters shared by search and query parse lists, dates and flags, and escape strings" do
    conds = ApiData.conditions(%{"country" => "us, fr", "business_model" => "SaaS,Agency", "revenue" => "$1M-$10M",
                                 "first_seen_after" => "2026-10-01", "has_named_email" => "true", "shopify" => "1",
                                 "tech" => "Klaviyo'; DROP TABLE businesses; --"})
    joined = Enum.join(conds, " AND ")
    assert "estimated_country IN ('US', 'FR')" in conds
    assert "estimated_business_model IN ('SaaS', 'Agency')" in conds
    assert "estimated_revenue = '$1M-$10M'" in conds
    assert "ctl_first_seen_at >= toDateTime('2026-10-01 00:00:00')" in conds
    assert "is_shopify = 1" in conds
    assert Enum.any?(conds, &String.starts_with?(&1, "arrayExists(e -> NOT match(e, '^(info|hello|"))
    # The quote is escaped, so the whole injection stays inside the literal.
    assert joined =~ "has(http_tech, 'Klaviyo\\' DROP TABLE businesses --')"
    assert joined =~ "estimated_junk = ''"
  end

  test "a bad date, an empty list and an unknown flag value are ignored, never passed through" do
    conds = ApiData.conditions(%{"first_seen_after" => "yesterday", "country" => "", "hiring" => "maybe", "employees" => " , "})
    assert conds == ["http_title != ''", "estimated_junk = ''"]
  end

  test "the sort keys are a fixed list and the default is the target ranking" do
    assert ApiData.sort_keys() == ~w(first_seen jobs last_checked products relevance tranco)
    assert "sort" in ApiData.search_filters()
    assert "has_named_email" in ApiData.search_filters()
  end

  test "group_by accepts only the listed columns" do
    assert ApiData.group_by_fields() == ~w(estimated_business_model estimated_country estimated_revenue estimated_employees estimated_industry dns_email_provider ctl_tld)
  end

  test "the role regex for SQL names the role mailboxes and nothing that breaks the literal" do
    sql = LS.HTTP.EmailClass.role_regex_sql()
    assert String.starts_with?(sql, "'^(")
    assert String.ends_with?(sql, "[-_.+]?[a-z0-9]*@'")
    refute sql =~ "''"
  end

  test "the query tool is listed with its bounds and the search tool documents sort" do
    tools = LSWeb.McpController.tools()
    q = Enum.find(tools, &(&1.name == "listsignal_query"))
    assert q, "listsignal_query missing"
    assert q.description =~ "500 rows"
    assert q.description =~ "ten seconds"
    props = q.inputSchema.properties |> Map.keys() |> Enum.map(&to_string/1)
    for p <- ~w(sort fields group_by limit offset has_named_email first_seen_after country business_model), do: assert(p in props, p)

    s = Enum.find(tools, &(&1.name == "listsignal_search_companies"))
    assert Map.has_key?(s.inputSchema.properties, :sort)
    assert s.description =~ "target ranking"
  end
end
