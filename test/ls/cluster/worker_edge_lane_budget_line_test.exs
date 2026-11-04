defmodule LS.Cluster.WorkerEdgeLaneBudgetLineTest do
  @moduledoc """
  2026-11-04, 20:30 UTC: with the lane keeping what it finished, ny1 still
  cut 7 to 11 of every batch, one store a batch, and the fleet wrote 30
  to 80 Shopify rows a quarter hour while the node's Shopify line sat
  idle. The lane's single task waited for every request on the discovery
  line of the node budget, booked 92 s ahead by 300 plain fetch tasks.
  The lane now draws on the depth lane's reserved line (30 a minute, the
  Shopify line's own rate, idle on the duals), so a store waits behind
  depth pages only. The ceiling is unchanged: the reserve was already
  counted, and discovery borrows it only while it is idle.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkerAgent

  @edge_ip "23.227.38.65"
  @plain_ip "93.184.216.34"

  test "a store in the lane fetches on the depth lane's line, a plain site on the discovery line" do
    fun = fn {d, _ip} -> {d, Process.get(:ls_fetch_lane, :discovery)} end
    until = System.monotonic_time(:millisecond) + 5_000
    {res, cut} = WorkerAgent.fetch_split([{"store.test", @edge_ip}, {"plain.test", @plain_ip}], &elem(&1, 1), fun, 4, 10_000, until)

    assert cut == 0
    assert res["store.test"] == :enrichment
    assert res["plain.test"] == :discovery
    assert WorkerAgent.edge_budget_lane() == :enrichment
  end

  test "the depth lane's reserve is the Shopify line's rate and its horizon holds the lanes" do
    # 30 requests a minute reserved by default (LS_ENRICH_FETCH_PER_MIN), 2 s spacing on the edge.
    assert LS.HTTP.NodeBudget.enrich_per_min() == 30
    assert LS.HTTP.IPRateLimiter.min_spacing_ms(@edge_ip) == 2_000
    assert div(60_000, LS.HTTP.IPRateLimiter.min_spacing_ms(@edge_ip)) == LS.HTTP.NodeBudget.enrich_per_min()

    for batches <- 1..4 do
      depth = WorkerAgent.edge_width(batches) * batches * LS.HTTP.IPRateLimiter.min_spacing_ms(@edge_ip)
      assert depth < LS.HTTP.Client.book_horizon_ms(WorkerAgent.edge_budget_lane())
    end
  end

  test "the lane's tag does not leak into the batch process" do
    fun = fn {d, _ip} -> {d, :ok} end
    until = System.monotonic_time(:millisecond) + 5_000
    {_res, 0} = WorkerAgent.fetch_split([{"store.test", @edge_ip}], &elem(&1, 1), fun, 4, 10_000, until)
    assert Process.get(:ls_fetch_lane) == nil
  end
end
