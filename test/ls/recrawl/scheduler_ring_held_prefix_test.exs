defmodule LS.Recrawl.SchedulerRingHeldPrefixTest do
  @moduledoc """
  2026-11-04 07:42 to 09:00 UTC: the sliced tier A tick (e3d6595) went
  live and enqueued 0, 6, 1 and 0 names a slice for ninety minutes while
  the old tick had enqueued 3,600 to 4,500. The due list is oldest first,
  and the names the stable and dormant rings hold (refused even when
  forced) sit at its head: about 17,000 that morning. A whole tick read
  four blocks of 5,625 rows and found fresh names in its fourth; a slice
  read four blocks of 937 and never left the held prefix, counting every
  held name against its allowance ("750 taken, refused
  %{recently_crawled: 750}"). Meanwhile the fleet crawled no tier A
  business at all, the thing the lane exists for.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.{CrawlDedup, WorkQueue}
  alias LS.Recrawl.Scheduler

  setup do
    for name <- [:stable, :dormant, :hot] do
      :persistent_term.put({CrawlDedup, name}, %{blooms: fresh(name), rotated_at: System.system_time(:second)})
    end

    :ok
  end

  defp fresh(:stable), do: for(_ <- 1..5, do: LS.Reputation.Bloom.new(10_000, 0.001))
  defp fresh(:dormant), do: for(_ <- 1..3, do: LS.Reputation.Bloom.new(10_000, 0.02))
  defp fresh(:hot), do: for(_ <- 1..4, do: LS.Reputation.Bloom.new(10_000, 0.01))

  test "a name the stable or dormant ring holds is held; a hot one or an unknown one is not" do
    CrawlDedup.mark_stable(["calm.example"])
    CrawlDedup.mark_dormant(["sleepy.example"])
    CrawlDedup.mark_dormant(["moving.example"])
    CrawlDedup.mark_hot(["moving.example"])
    assert WorkQueue.ring_held?("calm.example")
    assert WorkQueue.ring_held?("sleepy.example")
    refute WorkQueue.ring_held?("moving.example"), "a recorded change puts a name back on the schedule"
    refute WorkQueue.ring_held?("fresh.example")
    refute WorkQueue.ring_held?("")
    refute WorkQueue.ring_held?(nil)
  end

  test "held is exactly what a forced enqueue refuses, so the scheduler and the queue agree" do
    CrawlDedup.mark_stable(["agree.example"])
    assert WorkQueue.ring_held?("agree.example")
    assert WorkQueue.enqueue(%{ctl_domain: "agree.example", source: :recrawl, tier: "a"}, force: true) == :recently_crawled
  end

  test "a slice reads blocks the size of a tick's and as far down the list as a tick, so the held prefix cannot starve it" do
    src = File.read!("lib/ls/recrawl/scheduler.ex")
    assert src =~ ~s|lane(["a"], first, a_block())|
    assert src =~ ~s|lane(["a"], allowance, a_block())|
    assert src =~ "LS.Cluster.WorkQueue.ring_held?(d)"
    assert src =~ "when pass * block >= @read_cap or enqueued >= target"
    plan = Scheduler.plan()
    # Fresh tier A names were found past offset 16,875 on 2026-11-03 and 04.
    assert plan.max_passes * plan.batch_size >= 22_500
    assert Scheduler.a_block() * 4 >= 22_500, "four blocks must reach where the old tick found fresh names"
  end
end
