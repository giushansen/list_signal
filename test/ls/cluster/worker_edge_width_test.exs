defmodule LS.Cluster.WorkerEdgeWidthTest do
  @moduledoc """
  2026-11-04, first hour of the shared-edge lane (e3d6595): the lane was
  four wide per batch and a dual runs three batches, so twelve tasks kept
  the Shopify line 23 to 24 s deep on ny1 and sg2 between waves. Under
  the 30 s discovery horizon, so the lane itself was never refused, but
  over the 5 s a redirect hop tolerated and the 10 s depth horizon: one
  Shopify store in five ended as a bare 301 row and the catalog fetches
  came back as our own refusals. The width is now per node, shared by the
  batches.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  test "the edge lane is four wide per node whatever the batch count" do
    assert WorkerAgent.edge_width(1) == 4
    assert WorkerAgent.edge_width(2) == 2
    assert WorkerAgent.edge_width(3) == 1
    assert WorkerAgent.edge_width(4) == 1
  end

  test "the line the batches book together stays inside the depth lane's horizon" do
    # Every booking on the Shopify edge is 2 s apart; the depth lane sleeps
    # at most its horizon for a place, and so does a redirect hop in that lane.
    spacing = LS.HTTP.IPRateLimiter.min_spacing_ms("23.227.38.65")
    assert spacing == 2_000

    for batches <- 1..4 do
      depth = WorkerAgent.edge_width(batches) * batches * spacing
      assert depth < LS.HTTP.Client.book_horizon_ms(:enrichment), "#{batches} batches book #{depth} ms ahead"
    end
  end

  test "the lane width comes from the node's batch count" do
    src = File.read!("lib/ls/cluster/worker_agent.ex")
    assert src =~ "run_until(edge, fun, edge_width(parallel_batches()), timeout, until)"
  end
end
