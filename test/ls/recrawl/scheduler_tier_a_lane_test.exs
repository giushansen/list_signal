defmodule LS.Recrawl.SchedulerTierALaneTest do
  @moduledoc """
  2026-10-23 14:04 UTC to 2026-10-24: the queue sat over its 150K headroom
  and the scheduler enqueued nothing for 12 hours, tier A included, while
  certificate inflow alone outran six workers. The businesses whose
  changes are the product were not being refreshed at all. Tier A is now
  admitted every tick up to its allowance; B and C still yield to discovery.
  """
  use ExUnit.Case, async: true

  alias LS.Recrawl.Scheduler

  test "tier A is admitted over the headroom until its allowance is spent" do
    plan = Scheduler.plan()
    assert Scheduler.admit?("a", 0, true)
    assert Scheduler.admit?("a", plan.tier_a_per_tick - 1, true)
    refute Scheduler.admit?("a", plan.tier_a_per_tick, true)
    refute Scheduler.admit?("a", plan.tier_a_per_tick + 10, false)
  end

  test "tier B and C yield to discovery when the queue is over the headroom" do
    refute Scheduler.admit?("b", 0, true)
    refute Scheduler.admit?("c", 0, true)
    assert Scheduler.admit?("b", 0, false)
    assert Scheduler.admit?("c", 0, false)
  end

  test "the tier A allowance matches the 14-day plan, not the whole fleet" do
    plan = Scheduler.plan()
    assert plan.tier_a_per_tick < plan.batch_size
    # 3.13M tier A businesses every 14 days is 223K a day; six nodes fetch
    # roughly twice that, so tier A takes about half and discovery the rest.
    assert plan.tier_a_per_day in 180_000..260_000
    assert plan.tier_a_per_day == plan.runs_per_day * plan.tier_a_per_tick
  end

  test "each lane reads only its own tiers from the due list, so no pass resolves names it cannot admit" do
    # First tick on 2026-10-24: 3.1M tier A rows were overdue and sorted first, so
    # the three passes after the allowance resolved 37,500 names and admitted none.
    a = LS.Clickhouse.stale_domains_sql(5_625, 0, ["a"])
    assert a =~ "AND tier IN ('a')"
    assert a =~ "ORDER BY tier ASC, http_last_checked_at ASC, domain"
    bc = LS.Clickhouse.stale_domains_sql(12_500, 12_500, ["b", "c"])
    assert bc =~ "AND tier IN ('b', 'c')"
    refute LS.Clickhouse.stale_domains_sql(1000) =~ "tier IN"
    # Only the three known tiers reach the SQL; anything else selects nothing.
    hostile = LS.Clickhouse.stale_domains_sql(10, 0, ["a') OR 1=1 --"])
    refute hostile =~ "1=1"
    assert hostile =~ "AND 0"
    assert LS.Clickhouse.stale_domains_sql(10, 0, ["c", "zzz"]) =~ "AND tier IN ('c')"
  end

  test "a business fetched in the last day is never due, whatever its compiled stamp says" do
    # 2026-10-24 14:00-16:00 local, after the priority lane shipped: 12K
    # known businesses fetched twice by two nodes 40-80 minutes apart. The
    # refresh had landed in enrich_log; the compiled row still said overdue.
    sql = LS.Clickhouse.stale_domains_sql(1000, 0, ["a"])
    assert sql =~ "AND domain NOT IN (SELECT domain FROM enrich_log WHERE enriched_at >= now() - INTERVAL 1 DAY)"
    assert LS.Clickhouse.stale_domains_sql(1000) =~ "NOT IN (SELECT domain FROM enrich_log"
  end

  test "the tier A block is a little over the allowance, never the whole batch" do
    plan = Scheduler.plan()
    assert Scheduler.a_block() >= plan.tier_a_per_tick
    assert Scheduler.a_block() <= div(plan.tier_a_per_tick * 3, 2)
    assert Scheduler.a_block() <= plan.batch_size
  end

  test "the item the scheduler builds for tier A lands in the priority lane" do
    item = %{ctl_domain: "shop.example", source: :recrawl, tier: "a", prev_simhash: 12_345}
    assert LS.Cluster.WorkQueue.priority(item) == 0
    assert LS.Cluster.WorkQueue.priority(%{item | tier: "b"}) == 1
  end
end
