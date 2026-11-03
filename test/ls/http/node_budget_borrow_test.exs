defmodule LS.HTTP.NodeBudgetBorrowTest do
  @moduledoc """
  2026-11-03: on every dual the depth lane's reserved 30 of 120 slots a
  minute sat idle (enrichment line backlog 0 on chi1, par1, dal1 and ny1,
  107 depth fetches a minute fleet-wide against 270 reserved) while the
  discovery line was booked 60 to 127 s ahead. Discovery now runs at the
  whole ceiling while the depth line is quiet and drops back to its share
  the moment the depth lane takes a slot.
  """
  use ExUnit.Case, async: false

  alias LS.HTTP.NodeBudget

  setup do
    NodeBudget.init()
    :ets.delete_all_objects(:http_node_budget)
    prev = {System.get_env("LS_LANES"), System.get_env("LS_FETCH_PER_MIN"), System.get_env("LS_ENRICH_FETCH_PER_MIN")}
    System.put_env("LS_LANES", "discovery,enrichment")
    System.put_env("LS_FETCH_PER_MIN", "120")
    System.delete_env("LS_ENRICH_FETCH_PER_MIN")

    on_exit(fn ->
      {lanes, per_min, enrich} = prev
      restore("LS_LANES", lanes)
      restore("LS_FETCH_PER_MIN", per_min)
      restore("LS_ENRICH_FETCH_PER_MIN", enrich)
    end)

    :ok
  end

  defp restore(k, nil), do: System.delete_env(k)
  defp restore(k, v), do: System.put_env(k, v)

  test "with the depth line idle, discovery runs at the ceiling, not its share" do
    assert NodeBudget.enrichment_idle?()
    assert NodeBudget.lane_limit(:discovery) == 90
    assert NodeBudget.effective_limit(90, :discovery) == 120
  end

  test "the moment the depth lane takes a slot, discovery is back to its share" do
    assert :ok = NodeBudget.take(30, :enrichment)
    refute NodeBudget.enrichment_idle?()
    assert NodeBudget.effective_limit(90, :discovery) == 90
  end

  test "borrowing never passes the ceiling and never lowers what was asked" do
    assert NodeBudget.effective_limit(120, :discovery) == 120
    assert NodeBudget.effective_limit(200, :discovery) == 200
  end

  test "the depth lane itself never borrows" do
    assert NodeBudget.effective_limit(30, :enrichment) == 30
  end

  test "on a single-lane node there is nothing to borrow" do
    System.put_env("LS_LANES", "discovery")
    assert NodeBudget.effective_limit(120, :discovery) == 120
    System.put_env("LS_LANES", "enrichment")
    assert NodeBudget.effective_limit(120, :discovery) == 120
  end

  test "slots are spaced at the borrowed rate: 120 a minute is 500 ms apart" do
    assert :ok = NodeBudget.take(90, :discovery)
    assert {:wait, a} = NodeBudget.take(90, :discovery)
    assert {:wait, b} = NodeBudget.take(90, :discovery)
    assert a <= 500 and b - a <= 505 and b - a >= 495
  end

  test "hop and not-modified counters start at zero and count" do
    assert NodeBudget.counts() == %{}
    NodeBudget.count(:hop)
    NodeBudget.count(:hop)
    NodeBudget.count(:not_modified)
    assert NodeBudget.counts() == %{hop: 2, not_modified: 1}
  end
end
