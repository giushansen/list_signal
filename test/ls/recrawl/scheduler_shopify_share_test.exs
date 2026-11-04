defmodule LS.Recrawl.SchedulerShopifyShareTest do
  @moduledoc """
  2026-11-04, 09:20 to 10:30 UTC, the shared-edge lane on and the sliced
  tick enqueuing 750 names every five minutes: 42% of the due tier A
  list was Shopify (250,923 of 594,488), tier A items are dequeued first,
  and every store on a node goes through one 2 s line at Shopify's edge.
  Each batch filled with stores the line could not serve in its 420 s
  window, the deadline cut 21 to 60 of 74 to 86 candidates a batch, the
  cut stores returned to the head of the queue and refilled the next
  batch, and plain names waited behind them: sg2 wrote 14 to 61 rows a
  batch, the fleet 2,000 rows a quarter hour against 3,100 before the
  tier A items arrived. The scheduler now admits Shopify stores at the
  fleet's edge capacity and fills the rest of a slice with plain names.
  """
  use ExUnit.Case, async: true

  alias LS.Recrawl.Scheduler

  test "the due query can read the Shopify stores or the plain names alone, and both as before" do
    assert LS.Clickhouse.stale_domains_sql(100, 0, ["a"], true) =~ "AND is_shopify = 1"
    assert LS.Clickhouse.stale_domains_sql(100, 0, ["a"], false) =~ "AND is_shopify = 0"
    both = LS.Clickhouse.stale_domains_sql(100, 0, ["a"])
    refute both =~ "AND is_shopify ="
    # Anything that is not a boolean is both: no hostile value reaches the SQL.
    refute LS.Clickhouse.stale_domains_sql(100, 0, ["a"], "1 OR 1=1") =~ "1=1"
    refute LS.Clickhouse.stale_domains_sql(100, 0, ["a"], "1 OR 1=1") =~ "is_shopify ="
    # The three-tuple shape of the due list is unchanged (Liveness.partition/1 reads it).
    assert both =~ "SELECT domain, tier, http_body_simhash FROM ("
    assert both =~ ", http_body_simhash, is_shopify\n"
  end

  test "the Shopify share of a slice is under what the fleet's edge lines serve in five minutes" do
    plan = Scheduler.plan()
    # Seven duals, 30 edge requests a minute each, four to eight requests a store.
    stores_per_five_minutes = div(7 * 30 * 5, 4)
    assert plan.tier_a_shopify_per_slice <= div(stores_per_five_minutes, 2), "leave the line room for the stores certificates bring"
    assert plan.tier_a_shopify_per_slice >= 60, "tier A Shopify stores must still be refreshed"
    assert Scheduler.shopify_share(plan.tier_a_per_slice) == plan.tier_a_shopify_per_slice
    assert Scheduler.shopify_share(50) == 50
    assert Scheduler.shopify_share(0) == 0
  end

  test "a tier A lane reads the plain list up to the allowance less the share, then the Shopify list up to the share" do
    src = File.read!("lib/ls/recrawl/scheduler.ex")
    assert src =~ ~s|lane(["a"], target - shop, block, false)|
    assert src =~ ~s|lane(["a"], shop, block, true)|
    assert src =~ "shop = shopify_share(target)"
    assert src =~ "LS.Clickhouse.stale_domains(block, pass * block, tiers, shopify)"
  end
end
