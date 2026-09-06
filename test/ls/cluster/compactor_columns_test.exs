defmodule LS.Cluster.CompactorColumnsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins for the 2026-09-06 compactor changes. The compactor is one long SQL
  string, so a column that is added to a table but not to every list here
  is silently dropped at the next pass (that is how the RDAP registrant
  country was dead for a month, see migration 018).
  """

  @src File.read!("lib/ls/clickhouse.ex")

  test "email-auth columns travel from domains_history to businesses" do
    for col <- ~w(dns_dmarc dns_bimi dns_dkim) do
      assert @src =~ "#{col} AS s_#{col}", "#{col} missing from the history subselect"
      assert @src =~ "AS #{col},", "#{col} missing from the argMaxIf fold"
      assert @src =~ "h.#{col}", "#{col} missing from the businesses select"
      assert @src =~ ~r/INSERT INTO businesses \([^)]*\b#{col}\b/, "#{col} missing from the INSERT list"
    end
  end

  test "email-auth folds key on dns_mx, not on themselves: an empty record is a real answer" do
    # A domain that has mail and no DMARC is a measured '' — the fold must
    # keep the newest row WITH mail, or a stale policy would never clear.
    assert @src =~ "argMaxIf(s_dns_dmarc, s_enriched_at, s_dns_mx != '')"
  end

  test "depth apps are unioned into http_apps, never replace it" do
    assert @src =~ "arrayConcat(splitByChar('|', h.http_apps), splitByChar('|', ifNull(s.apps_deep, '')))"
  end

  test "store shape columns travel from biz_enrichment to businesses" do
    for col <- ~w(shop_theme shop_theme_store_id shop_currency shop_locales shopify_plus) do
      assert @src =~ "AS #{col},", "#{col} missing from the enrichment fold"
      assert @src =~ "s.#{col}", "#{col} missing from the businesses select"
      assert @src =~ ~r/INSERT INTO businesses \([^)]*\b#{col}\b/, "#{col} missing from the INSERT list"
    end

    assert ~w(apps_deep shop_theme shop_theme_store_id shop_currency shop_locales shopify_plus) --
             LS.Cluster.EnrichmentWriter.summary_columns() == []
  end

  test "sitemap snapshot and the depth estimate travel from biz_enrichment to businesses (2026-09-06)" do
    for col <- ~w(sitemap_urls sitemap_products sitemap_blog sitemap_children sitemap_lastmod sitemap_hash) do
      assert @src =~ "AS #{col},", "#{col} missing from the enrichment fold"
      assert @src =~ "s.#{col}", "#{col} missing from the businesses select"
      assert @src =~ ~r/INSERT INTO businesses \([^)]*\b#{col}\b/, "#{col} missing from the INSERT list"
    end

    assert @src =~ "if(ifNull(s.d_est_revenue, '') != '', s.d_est_revenue, h.estimated_revenue) AS estimated_revenue"
    assert @src =~ "argMaxIf(depth_revenue_evidence, enriched_at, depth_estimated_revenue != '') AS d_rev_evidence"

    assert ~w(sitemap_urls sitemap_hash depth_estimated_revenue depth_revenue_evidence) --
             LS.Cluster.EnrichmentWriter.summary_columns() == []
  end

  test "infrastructure DNS columns travel to businesses (2026-09-06)" do
    for col <- ~w(dns_ptr dns_ms_enterprise) do
      assert @src =~ "#{col} AS s_#{col}"
      assert @src =~ "AS #{col},"
      assert @src =~ "h.#{col}"
      assert @src =~ ~r/INSERT INTO businesses \([^)]*\b#{col}\b/
    end
  end

  test "subdomains are a union across certificates and suppressed sightings, capped" do
    assert @src =~ "arrayFlatten(groupArray(splitByChar('|', s_ctl_subdomains))))), 1, 300) AS _subs_hist"
    assert @src =~ "FROM ctl_sightings\#{join_scope}"
    assert length(String.split(@src, "arraySlice(arrayDistinct(arrayConcat(h._subs_hist, ifNull(c.subs, []))), 1, 300)")) == 3,
           "the union must feed BOTH ctl_subdomain_count and ctl_subdomains"
  end

  describe "verified facts (google.com was a 3-person company, 2026-09-06)" do
    test "among entities sharing a website, the largest wins" do
      assert @src =~ "ORDER BY fetched_at DESC, toFloat64OrZero(value) DESC\n        LIMIT 1 BY domain, fact, source"
    end

    test "a fact that contradicts a top-10K Tranco rank is blanked, source included" do
      assert @src =~ "if(h.tranco_rank <= 10000 AND v.verified_revenue IN ('<$1M', '$1M-$10M'), '', v.verified_revenue) AS verified_revenue"
      assert @src =~ "if(h.tranco_rank <= 10000 AND v.verified_revenue IN ('<$1M', '$1M-$10M'), '', v.verified_revenue_source) AS verified_revenue_source"
      assert @src =~ "if(h.tranco_rank <= 10000 AND v.verified_employees IN ('1-10', '11-50'), '', v.verified_employees) AS verified_employees"
    end
  end

  test "the migration exists for every new column and the sightings table" do
    sql = File.read!("clickhouse/migrations/020_email_auth_shop_shape_sightings.sql")

    for col <- ~w(dns_dmarc dns_bimi dns_dkim shop_theme shop_theme_store_id shop_currency shop_locales shopify_plus apps_deep) do
      assert sql =~ col
    end

    assert sql =~ "CREATE TABLE IF NOT EXISTS ls.ctl_sightings"
    assert sql =~ "TTL seen_at + INTERVAL 90 DAY"
  end
end
