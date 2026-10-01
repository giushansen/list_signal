defmodule LS.HTTP.NodeBudgetTest do
  @moduledoc """
  A per-node cap on fetches per minute (2026-10-01). The per-IP limiter
  protected destinations; nothing capped our own source address: workers
  averaged 119 fetches a minute with bursts of 355 against a measured safe
  envelope of 130 to 160. The first cap counted per wall-clock minute and
  100 concurrent tasks spent it in the first seconds, so 12.9% of fetches
  gave up; slots are now spaced evenly and reserved, never refused unless
  the line is five minutes long.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.NodeBudget

  setup do
    NodeBudget.init()
    :ets.delete_all_objects(:http_node_budget)
    :ok
  end

  test "slots are spaced evenly: the first is free, the next ones wait one interval each" do
    assert NodeBudget.take(60) == :ok
    assert {:wait, a} = NodeBudget.take(60)
    assert {:wait, b} = NodeBudget.take(60)
    assert a > 0 and a <= 1_000
    assert b > a and b <= 2_000
  end

  test "an idle line does not bank a burst" do
    assert NodeBudget.take(6000) == :ok
    Process.sleep(50)
    # 10 ms interval, 50 ms idle: the next take is free, the one after waits ~10 ms, not 0
    assert NodeBudget.take(6000) == :ok
    assert {:wait, ms} = NodeBudget.take(6000)
    assert ms <= 10
  end

  test "a line longer than seven minutes refuses instead of queueing; a batch-sized line does not" do
    for _ <- 1..300, do: NodeBudget.take(60)
    assert {:wait, _} = NodeBudget.take(60), "300 s of line is a large batch"
    for _ <- 1..121, do: NodeBudget.take(60)
    assert NodeBudget.take(60) == :overloaded
  end

  test "the default ceiling sits inside the measured envelope" do
    assert NodeBudget.per_min() >= 100 and NodeBudget.per_min() <= 160
  end
end
