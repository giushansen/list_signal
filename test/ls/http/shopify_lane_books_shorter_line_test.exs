defmodule LS.HTTP.ShopifyLaneBooksShorterLineTest do
  @moduledoc """
  2026-11-07, par1 03:47 UTC, one sample a second for two minutes: the
  node budget's depth line was booked 13.5 s ahead at the median and was
  never free, held by the three batches' Shopify lanes and about four
  depth-lane tasks at 2 s a slot. The discovery line was free in 47 of
  120 samples and Shopify's own 2 s line was idle in all 120. A store of
  three requests waited about 40 s for budget slots, a lane finished
  about eight stores a window, and 85,000 Shopify stores waited in the
  master's queue. A request of the Shopify lane now books the shorter of
  the two lines. These tests hold the two things that must not move: the
  node never sends more than its ceiling, and the depth lane keeps its
  own line.
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
      :ets.delete_all_objects(:http_node_budget)
    end)

    :ok
  end

  defp restore(k, nil), do: System.delete_env(k)
  defp restore(k, v), do: System.put_env(k, v)

  test "the shorter line wins, the depth line on a tie, discovery on a one-lane node" do
    assert NodeBudget.edge_line(true, 13_500, 0) == :discovery
    assert NodeBudget.edge_line(true, 0, 8_000) == :enrichment
    assert NodeBudget.edge_line(true, 4_000, 4_000) == :enrichment
    assert NodeBudget.edge_line(true, 0, 0) == :enrichment
    # A one-lane node gives every line the whole ceiling: the depth line
    # there would be a second full line, so the lane stays on discovery.
    assert NodeBudget.edge_line(false, 0, 90_000) == :discovery
    # Anything that is not a pair of integers keeps the lane's own line.
    assert NodeBudget.edge_line(true, nil, 0) == :enrichment
    assert NodeBudget.edge_line(true, 5_000, :busy) == :enrichment
  end

  test "with the depth line booked deep and discovery free, the Shopify lane takes a discovery slot at once" do
    for _ <- 1..7, do: NodeBudget.take(30, :enrichment)
    assert NodeBudget.backlog_ms(:enrichment) >= 10_000
    assert NodeBudget.backlog_ms(:discovery) == 0

    line =
      run_in_lane(fn ->
        LS.HTTP.Client.budget_line(:enrichment)
      end)

    assert line == :discovery
    assert :ok = NodeBudget.take(NodeBudget.lane_limit(line), line)
    assert NodeBudget.counts()[:edge_on_discovery] == 1
  end

  test "the depth lane itself still books its own line, however deep it is" do
    for _ <- 1..7, do: NodeBudget.take(30, :enrichment)
    assert LS.HTTP.Client.budget_line(:enrichment) == :enrichment
    assert LS.HTTP.Client.budget_line(:discovery) == :discovery
  end

  test "every Shopify request uses exactly one slot of one line: the ceiling is unchanged" do
    # 60 requests through the lane, starting from idle lines. Each one
    # moves one line forward by one of its own intervals, so the work
    # booked equals the requests made, whatever line each one chose.
    disc = div(60_000, NodeBudget.lane_limit(:discovery))
    enr = div(60_000, NodeBudget.lane_limit(:enrichment))

    run_in_lane(fn ->
      for _ <- 1..60 do
        line = LS.HTTP.Client.budget_line(:enrichment)
        NodeBudget.take(NodeBudget.lane_limit(line), line)
      end
    end)

    c = NodeBudget.counts()
    assert c[:edge_on_discovery] + c[:edge_on_enrichment] == 60
    booked = div(NodeBudget.backlog_ms(:discovery), disc) + div(NodeBudget.backlog_ms(:enrichment), enr)
    assert booked in 58..60, "#{booked} slots booked for 60 requests"
    # Both lines filled, neither past what the two shares add up to in the time booked.
    assert NodeBudget.backlog_ms(:discovery) > 0 and NodeBudget.backlog_ms(:enrichment) > 0
  end

  test "on a one-lane node the Shopify lane never opens a second line" do
    System.put_env("LS_LANES", "discovery")

    lines = run_in_lane(fn -> for _ <- 1..10, do: LS.HTTP.Client.budget_line(:enrichment) end)
    assert Enum.uniq(lines) == [:discovery]
  end

  test "the worker's lane sets the flag inside its tasks, never in the batch process" do
    fun = fn {d, _ip} -> {d, Process.get(:ls_edge_lane)} end
    until = System.monotonic_time(:millisecond) + 5_000
    {res, 0} = LS.Cluster.WorkerAgent.fetch_split([{"store.test", "23.227.38.65"}, {"plain.test", "93.184.216.34"}], &elem(&1, 1), fun, 4, 10_000, until)
    assert res["store.test"] == true
    assert res["plain.test"] == nil
    assert Process.get(:ls_edge_lane) == nil
  end

  defp run_in_lane(fun) do
    Task.async(fn ->
      Process.put(:ls_fetch_lane, :enrichment)
      Process.put(:ls_edge_lane, true)
      fun.()
    end)
    |> Task.await()
  end
end
