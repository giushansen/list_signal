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

  test "the item the scheduler builds for tier A lands in the priority lane" do
    item = %{ctl_domain: "shop.example", source: :recrawl, tier: "a", prev_simhash: 12_345}
    assert LS.Cluster.WorkQueue.priority(item) == 0
    assert LS.Cluster.WorkQueue.priority(%{item | tier: "b"}) == 1
  end
end
