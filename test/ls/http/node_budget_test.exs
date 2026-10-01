defmodule LS.HTTP.NodeBudgetTest do
  @moduledoc """
  A per-node cap on fetches per minute (2026-10-01). The per-IP limiter
  protected destinations; nothing capped our own source address, and after
  the crawl-gate change workers averaged 119 fetches a minute with bursts
  of 355 against a measured safe envelope of 130 to 160.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.NodeBudget

  test "the budget admits `limit` fetches in a minute and then asks the caller to wait for the next one" do
    NodeBudget.init()
    :ets.delete_all_objects(:http_node_budget)
    results = for _ <- 1..5, do: NodeBudget.take(3)
    assert Enum.take(results, 3) == [:ok, :ok, :ok]
    assert [{:wait, a}, {:wait, b}] = Enum.drop(results, 3)
    assert a > 0 and a <= 60_000 and b > 0 and b <= 60_000
    assert NodeBudget.used_this_minute() == 5
  end

  test "the default ceiling sits inside the measured envelope" do
    assert NodeBudget.per_min() >= 100 and NodeBudget.per_min() <= 160
  end
end
