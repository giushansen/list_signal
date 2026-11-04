defmodule LS.Cluster.WorkerEdgeLaneSwitchTest do
  @moduledoc """
  2026-11-04, four hours of the shared-edge lane on the seven duals: a
  batch's HTTP stage ran to its deadline whenever it held more Shopify
  stores than the line serves, all three batches sat in their HTTP stage
  at once, and each stage cut a third to two thirds of its candidates
  after spending slots on them. sg2 fell from 34 rows a minute to 24,
  the fleet's 2xx rows from about 180 a minute to 56 to 130, and the
  master queue grew from 40K to 74K in three hours. The lane is now off
  unless LS_EDGE_LANE=on, so a node can trial it alone as ny1 trialled
  the crawl rules on 2026-11-03.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  test "the lane is off unless asked for" do
    refute WorkerAgent.edge_lane?(nil)
    refute WorkerAgent.edge_lane?("")
    refute WorkerAgent.edge_lane?("off")
    refute WorkerAgent.edge_lane?("0")
    refute WorkerAgent.edge_lane?("yes please")
    assert WorkerAgent.edge_lane?("on")
    assert WorkerAgent.edge_lane?("1")
    assert WorkerAgent.edge_lane?("true")
  end

  test "both HTTP phases run the plain stream when the lane is off" do
    src = File.read!("lib/ls/cluster/worker_agent.ex")
    assert src =~ "if edge_lane?(),\n        do: fetch_split(cands, &elem(&1, 1), fetch, conc, bound, min(home_deadline, deadline)),\n        else: run_until(cands, fetch, conc, bound, min(home_deadline, deadline))"
    assert src =~ "else: run_until(due, fn {d, r, ip} -> {d, LS.Pipeline.secondary(r, d, ip)} end, conc, remaining, deadline)"
  end
end
