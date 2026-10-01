defmodule LS.ExplorerV2Test do
  @moduledoc """
  The explorer compiles its filters against the v2 product table
  (2026-10-01): exact array membership for technologies, estimated_ names
  for the classifier's columns, the spec's export list. A filter that
  compiled to the old column names would be a query that matches nothing.
  """
  use ExUnit.Case, async: true

  alias LS.Explorer

  test "tech filters are exact catalog names on the array, all of them required" do
    assert Explorer.where_sql(tech: "Shopify,Klaviyo") == "WHERE hasAll(http_tech, ['Shopify', 'Klaviyo'])"
    assert Explorer.where_sql(shopify_app: "Judge.me") == "WHERE hasAll(http_tech, ['Judge.me'])"
    refute Explorer.where_sql(tech: "Shopify") =~ "positionCaseInsensitive"
  end

  test "classifier, country and junk filters use the estimated_ columns" do
    assert Explorer.where_sql(country: "US,GB") =~ "estimated_country IN ('US','GB')"
    assert Explorer.where_sql(business_model: "Agency") =~ "estimated_business_model = 'Agency'"
    assert Explorer.where_sql(business_model: "SaaS") =~ "is_saas = 1"
    assert Explorer.where_sql(business_model: "Shopify") =~ "is_shopify = 1"
    assert Explorer.where_sql(industry: "Fintech") =~ "estimated_industry = 'Fintech'"
    assert Explorer.where_sql(exclude_junk: "true") =~ "estimated_junk = ''"
    assert Explorer.where_sql(dns_email_provider: "Google Workspace") =~ "dns_email_provider IN ('Google Workspace')"
  end

  test "depth filters use the prefixed columns and arrays test emptiness, not ''" do
    assert Explorer.where_sql(has_email: "true") =~ "notEmpty(http_emails)"
    assert Explorer.where_sql(hiring: "true") =~ "hr_job_count > 0"
    assert Explorer.where_sql(has_catalog: "true") =~ "shop_product_count > 0"
    assert Explorer.where_sql(has_pricing: "true") =~ "http_deep_pricing_points > 0"
    assert Explorer.where_sql(min_products: "10") =~ "shop_product_count >= 10.0"
    assert Explorer.where_sql(max_seo_score: "49") =~ "http_deep_seo_score <= 49.0 AND http_deep_seo_score IS NOT NULL"
    assert Explorer.where_sql(ats_platform: "Greenhouse") =~ "hr_ats = 'Greenhouse'"
  end

  test "discovered and freshness read the certificate and check timestamps" do
    assert Explorer.where_sql(discovered: "7d") =~ "ctl_first_seen_at >= now() - INTERVAL 7 DAY"
    assert Explorer.where_sql(freshness: "24h") =~ "http_last_checked_at >= now() - INTERVAL 1 DAY"
  end

  test "sortable columns are v2 names only" do
    for col <- Explorer.sortable_columns() do
      assert col in LS.Schema.Columns.names(), "#{col} is not a product column"
    end

    assert "shop_product_count" in Explorer.sortable_columns()
    refute "product_count" in Explorer.sortable_columns()
  end

  test "the list query selects v2 columns and no v1 name" do
    sql = Explorer.list_sql([tech: "Shopify"], per_page: 25, page: 1)
    assert sql =~ "estimated_business_model"
    assert sql =~ "http_tech"
    refute sql =~ "inferred_country"
    refute sql =~ "http_apps"
    refute sql =~ "as_of AS"
  end

  test "the export is the spec's exportable columns, one row per company, arrays flattened" do
    assert Explorer.export_columns() == LS.Schema.Columns.export_columns()
    assert "http_tech" in Explorer.export_columns()
    assert "estimated_revenue_evidence" in Explorer.export_columns()
    refute "compiled_at" in Explorer.export_columns()
  end
end
