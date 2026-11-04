defmodule LS.Recrawl.SchedulerSlicesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-11-03: the tier A tick put 4,467 Shopify-heavy businesses at
  priority 0 in one block every 30 minutes. Every node then started
  batches of 60 to 190 Shopify stores at once against a 2 s line, most
  were refused, and a store refused twice in the wave was shelved for its
  cadence (350 to 835 a wave). The allowance now goes out in slices
  inside the tick, each consumed before the next lands.
  """

  alias LS.Recrawl.Scheduler

  test "the slices add up to the tick's allowance and are spread inside the interval" do
    plan = Scheduler.plan()
    slices = Scheduler.slice_plan()
    assert length(slices) == plan.tier_a_slices
    assert plan.tier_a_slices >= 4, "one or two blocks a tick is still a wave"
    assert Enum.sum(Enum.map(slices, &elem(&1, 1))) == plan.tier_a_per_tick
    assert [{0, _} | _] = slices, "the first slice goes out at the tick"
    delays = Enum.map(slices, &elem(&1, 0))
    assert delays == Enum.sort(delays)
    assert List.last(delays) < plan.interval_ms, "every slice lands before the next tick"
    steps = delays |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
    assert Enum.uniq(steps) == [div(plan.interval_ms, plan.tier_a_slices)]
    assert plan.tier_a_per_slice <= 1_000, "a slice must be gone before the next one lands (a node does ~175 rows in five minutes)"
  end

  test "a slice reads a quarter more rows than it may enqueue, never past a run" do
    plan = Scheduler.plan()
    for {_, allowance} <- Scheduler.slice_plan() do
      assert Scheduler.slice_block(allowance) >= allowance
      assert Scheduler.slice_block(allowance) <= div(allowance * 3, 2)
      assert Scheduler.slice_block(allowance) <= plan.batch_size
    end
  end

  test "the tick enqueues the first slice and times the others; the B/C lane still gets the rest of the run" do
    src = File.read!("lib/ls/recrawl/scheduler.ex")
    assert src =~ "[{0, first} | later] = slice_plan()"
    assert src =~ "Process.send_after(self(), {:tier_a_slice, allowance}, delay)"
    assert src =~ "def handle_info({:tier_a_slice, allowance}, state) do"
    assert src =~ "lane([\"b\", \"c\"], quota_left(@tier_a_per_tick), @batch_size)"
  end
end
