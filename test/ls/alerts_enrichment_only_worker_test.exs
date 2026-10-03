defmodule LS.AlertsEnrichmentOnlyWorkerTest do
  use ExUnit.Case, async: true

  alias LS.Alerts

  @moduledoc """
  2026-10-03: h1 was moved to the enrichment lane only. It writes no
  discovery rows by design, so by evening the fleet-relative dead check
  read it as a dead worker. A node that says it runs no discovery lane is
  not expected to write discovery rows; a node that says nothing still is.
  """

  test "a connected enrichment-only node is not a dead discovery worker" do
    known = ["worker_lsny1@10.0.0.2", "worker_lsh1@10.0.0.7", "worker_lssg1@10.0.0.3"]
    lanes = %{"worker_lsny1@10.0.0.2" => ["discovery", "enrichment"], "worker_lsh1@10.0.0.7" => ["enrichment"]}
    assert Alerts.known_discovery_workers(known, lanes) == ["worker_lsny1@10.0.0.2", "worker_lssg1@10.0.0.3"]
  end

  test "a node that reports nothing stays known, so a dead node is still caught" do
    assert Alerts.known_discovery_workers(["worker_lsh1@10.0.0.7"], %{}) == ["worker_lsh1@10.0.0.7"]
    assert Alerts.known_discovery_workers(["worker_lsh1@10.0.0.7"], %{"worker_lsh1@10.0.0.7" => nil}) == ["worker_lsh1@10.0.0.7"]
  end

  test "hostile lane lists do not excuse a node" do
    assert Alerts.known_discovery_workers(["w@h"], %{"w@h" => []}) == []
    assert Alerts.known_discovery_workers(["w@h"], %{"w@h" => ["discovery"]}) == ["w@h"]
  end
end
