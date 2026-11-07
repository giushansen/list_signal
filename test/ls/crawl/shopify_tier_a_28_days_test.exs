defmodule LS.Crawl.ShopifyTierA28DaysTest do
  @moduledoc """
  2026-11-07: tier A Shopify stores were refreshed every 14 days like a
  SaaS site, while their detected tech changed half as often (3.5% under
  14 days against 5%, 6.9% at 14 to 30 against 13.4%, same-code visit
  pairs) and they are the scarcest fetch on the fleet (one 2 s line per
  node at Shopify's edge, 85,000 stores waiting in the master's queue).
  A tier A store is now due after 28 days; every other tier A business
  after 14.
  """
  use ExUnit.Case, async: true

  test "a tier A store waits 28 days, the tier itself still 14" do
    assert LS.Crawl.Tiers.shopify_a_days() == 28
    assert LS.Crawl.Tiers.cadence_days(:a) == 14
    assert LS.Crawl.Tiers.shopify_a_days() > LS.Crawl.Tiers.cadence_days(:a)
  end

  test "the due query holds back tier A stores checked inside 28 days, in every lane" do
    for {tiers, shop} <- [{nil, nil}, {["a"], true}, {["a"], false}, {["b", "c"], nil}] do
      sql = LS.Clickhouse.stale_domains_sql(100, 0, tiers, shop)
      assert sql =~ "AND NOT (is_shopify AND tier = 'a' AND http_last_checked_at >= now() - INTERVAL 28 DAY)"
      # The rule sits in the outer query, where tier and is_shopify are both projected.
      [_inner, outer] = String.split(sql, "\n)\n", parts: 2)
      assert outer =~ "is_shopify AND tier = 'a' AND http_last_checked_at >= now() - INTERVAL 28 DAY"
    end
  end
end
