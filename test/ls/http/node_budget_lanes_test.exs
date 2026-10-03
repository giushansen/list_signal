defmodule LS.HTTP.NodeBudgetLanesTest do
  use ExUnit.Case, async: false

  alias LS.HTTP.NodeBudget

  @moduledoc """
  2026-10-03: the day the node budget became airtight, two discovery
  batches kept the line full on every dual node and each depth fetch
  queued behind a minute of discovery slots. A depth domain visits up to
  four pages, so it blew its 120 s task timeout: ny1 dropped 108 of 120
  depth domains in an hour, chi1 101 of 112, and the fleet wrote 1,200
  depth rows an hour against 5,300 the day before. The enrichment lane now
  has its own line with a reserved share; the two shares add up to the
  ceiling so the source IP sends no more than before.
  """

  setup do
    NodeBudget.init()
    :ets.delete_all_objects(:http_node_budget)
    prev = {System.get_env("LS_LANES"), System.get_env("LS_FETCH_PER_MIN"), System.get_env("LS_ENRICH_FETCH_PER_MIN")}

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

  test "on a node running both lanes the shares add up to the ceiling" do
    System.put_env("LS_LANES", "discovery,enrichment")
    System.put_env("LS_FETCH_PER_MIN", "120")
    System.delete_env("LS_ENRICH_FETCH_PER_MIN")
    assert NodeBudget.lane_limit(:enrichment) == 30
    assert NodeBudget.lane_limit(:discovery) == 90
    assert NodeBudget.lane_limit(:discovery) + NodeBudget.lane_limit(:enrichment) == NodeBudget.per_min()
  end

  test "a single-lane node gives that lane the whole ceiling" do
    System.put_env("LS_FETCH_PER_MIN", "120")
    System.put_env("LS_LANES", "discovery")
    assert NodeBudget.lane_limit(:discovery) == 120
    System.put_env("LS_LANES", "enrichment")
    assert NodeBudget.lane_limit(:enrichment) == 120
  end

  test "an oversized reserve can never leave discovery without a slot" do
    System.put_env("LS_LANES", "discovery,enrichment")
    System.put_env("LS_FETCH_PER_MIN", "20")
    System.put_env("LS_ENRICH_FETCH_PER_MIN", "500")
    assert NodeBudget.lane_limit(:enrichment) == 19
    assert NodeBudget.lane_limit(:discovery) == 1
  end

  test "a full discovery line does not delay the enrichment line" do
    # Fill the discovery line two minutes deep.
    for _ <- 1..240, do: NodeBudget.take(120, :discovery)
    assert NodeBudget.backlog_ms(:discovery) > 100_000
    assert :ok = NodeBudget.take(30, :enrichment)
    assert {:wait, ms} = NodeBudget.take(30, :enrichment)
    assert ms <= 2_000, "the second enrichment slot is one enrichment interval away, not behind discovery"
  end

  test "the discovery line keeps its historical key and take/1 semantics" do
    assert :ok = NodeBudget.take(120)
    assert [{:next_at, _}] = :ets.lookup(:http_node_budget, :next_at)
    assert :ok = NodeBudget.take(30, :enrichment)
    assert [{{:next_at, :enrichment}, _}] = :ets.lookup(:http_node_budget, {:next_at, :enrichment})
  end

  test "the depth lane tags its task so every fetch it makes draws on its own line" do
    src = File.read!("lib/ls/enrichment/agent.ex")
    assert src =~ "Process.put(:ls_fetch_lane, :enrichment)"
    client = File.read!("lib/ls/http/client.ex")
    assert client =~ "Process.get(:ls_fetch_lane, :discovery)"
    assert client =~ "NodeBudget.take(LS.HTTP.NodeBudget.lane_limit(lane), lane)"
  end
end
