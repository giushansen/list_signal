defmodule LS.HTTP.NodeBudgetRaceTest do
  use ExUnit.Case, async: false

  alias LS.HTTP.NodeBudget

  @moduledoc """
  2026-10-03: with the queue full for the first time since the budget
  existed, nodes fetched 136 a minute on average and 186 on dal1 against a
  120 ceiling. Two defects: every concurrent caller that found the line
  idle was admitted at once (the reset came after), so each idle gap
  banked a burst; and the ETS table belonged to whichever fetch task first
  created it, so it died with that task and the line restarted idle at
  every batch boundary. An idle line is now claimed by one caller, and the
  table outlives its creator.
  """

  setup do
    NodeBudget.init()
    :ets.delete_all_objects(:http_node_budget)
    :ok
  end

  test "two hundred callers hitting an idle line at once get exactly one free slot, the rest are spaced" do
    results =
      1..200
      |> Task.async_stream(fn _ -> NodeBudget.take(120) end, max_concurrency: 200, timeout: 10_000)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.count(results, &(&1 == :ok)) == 1
    waits = for {:wait, ms} <- results, do: ms
    assert length(waits) == 199
    assert Enum.max(waits) <= 199 * 500 + 50, "199 slots at 500 ms each"
    assert Enum.min(waits) >= 400, "the second slot is a full interval away"
    assert length(Enum.uniq(waits)) == 199, "every caller holds a distinct slot"
  end

  test "any 120 consecutive slots span at least a minute, whatever the concurrency" do
    due =
      1..600
      |> Task.async_stream(fn _ -> NodeBudget.take(120) end, max_concurrency: 100, timeout: 10_000)
      |> Enum.map(fn
        {:ok, :ok} -> 0
        {:ok, {:wait, ms}} -> ms
      end)
      |> Enum.sort()

    assert length(due) == 600

    for i <- 0..(600 - 121) do
      span = Enum.at(due, i + 120) - Enum.at(due, i)
      assert span >= 59_000, "slots #{i}..#{i + 120} span only #{span} ms: more than 120 in a minute"
    end
  end

  test "the table survives the exit of the process that created it" do
    :ets.delete_all_objects(:http_node_budget)
    task = Task.async(fn -> NodeBudget.take(120) end)
    assert :ok = Task.await(task)
    # The task is gone; the table and its line are not.
    assert [{:next_at, _}] = :ets.lookup(:http_node_budget, :next_at)
    assert {:wait, _} = NodeBudget.take(120)
  end
end
