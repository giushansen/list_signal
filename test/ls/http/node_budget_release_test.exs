defmodule LS.HTTP.NodeBudgetReleaseTest do
  @moduledoc """
  2026-11-03: a fetch that took a node slot and then found its target's
  key booked too far ahead refused without a request, and the slot was
  lost: the line stayed advanced and the node sent one request fewer that
  minute. `release/2` hands the slot back.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.NodeBudget

  setup do
    NodeBudget.init()
    :ets.delete_all_objects(:http_node_budget)
    prev = {System.get_env("LS_LANES"), System.get_env("LS_FETCH_PER_MIN")}
    System.put_env("LS_LANES", "discovery")
    System.put_env("LS_FETCH_PER_MIN", "120")

    on_exit(fn ->
      {lanes, per_min} = prev
      if lanes, do: System.put_env("LS_LANES", lanes), else: System.delete_env("LS_LANES")
      if per_min, do: System.put_env("LS_FETCH_PER_MIN", per_min), else: System.delete_env("LS_FETCH_PER_MIN")
    end)

    :ok
  end

  test "a released slot moves the line back one interval for the next taker" do
    assert :ok = NodeBudget.take(120, :discovery)
    assert {:wait, _} = NodeBudget.take(120, :discovery)
    assert {:wait, _} = NodeBudget.take(120, :discovery)
    assert {:wait, before} = NodeBudget.take(120, :discovery)
    # Four slots are booked; give the last one back and take again.
    NodeBudget.release(120, :discovery)
    assert {:wait, after_release} = NodeBudget.take(120, :discovery)
    assert before - after_release >= -20 and before - after_release <= 20
    assert NodeBudget.counts()[:released] == 1
  end

  test "release never moves the line into the past: an idle line is left alone" do
    NodeBudget.release(120, :discovery)
    assert NodeBudget.backlog_ms(:discovery) == 0
    assert :ok = NodeBudget.take(120, :discovery)
    NodeBudget.release(120, :discovery)
    NodeBudget.release(120, :discovery)
    assert NodeBudget.backlog_ms(:discovery) == 0
    assert :ok = NodeBudget.take(120, :discovery)
  end

  test "each lane releases on its own line" do
    System.put_env("LS_LANES", "discovery,enrichment")
    assert :ok = NodeBudget.take(30, :enrichment)
    assert {:wait, e1} = NodeBudget.take(30, :enrichment)
    assert :ok = NodeBudget.take(90, :discovery)
    assert {:wait, _} = NodeBudget.take(90, :discovery)
    NodeBudget.release(90, :discovery)
    assert {:wait, e2} = NodeBudget.take(30, :enrichment)
    assert e2 - e1 >= 1_990 and e2 - e1 <= 2_010, "the enrichment line did not move"
  end
end
