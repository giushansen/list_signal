defmodule LS.AlertsEnrichmentDropsTest do
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Cluster.EnrichmentQueue

  @moduledoc """
  2026-10-03: the depth lane dropped nine domains in ten for eight hours
  (each depth domain queued behind a full discovery fetch budget and hit
  the agent's 120 s task timeout) while every alert stayed green: the
  queue was full, the refill healthy, the row count merely low. The share
  of domains a batch loses is the direct signal, kept on the master over
  the last 50 batches.
  """

  defp base do
    %{
      ingestion_3h: 600_000,
      per_worker: for(i <- 1..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 180_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}),
      known_workers: for(i <- 1..8, do: "worker_n#{i}@10.0.0.#{i}"),
      stale_seconds: 200,
      worker_health: %{},
      queue: %{queue_pct: 40.0, drain_rate_per_min: 4_000.0},
      node_resources: [],
      reputation_ages: %{tranco: 5, majestic: 6, blocklist: 3},
      backups: %{dir: "/home/ls/backups", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 20},
      enrichment_queue: %{http_starved_streak: 0, drop_share: {0, 50}},
      verification: %{scheduler: %{running: false, disabled: false}, sources: []},
      poller: nil,
      ctl_diff: %{new: [], retired: []},
      unmonitored_nodes: [],
      watchdog_restarts: [],
      data_check: %{quality: [], quantity: [], speed: []}
    }
  end

  defp keys(m), do: m |> Alerts.evaluate() |> Enum.map(& &1.key)

  test "nine in ten dropped over fifty batches is critical" do
    m = put_in(base(), [:enrichment_queue, :drop_share], {90, 50})
    assert "enrichment_drops" in keys(m)
  end

  test "a few lost domains, or too little history, stays quiet" do
    refute "enrichment_drops" in keys(put_in(base(), [:enrichment_queue, :drop_share], {12, 50}))
    refute "enrichment_drops" in keys(put_in(base(), [:enrichment_queue, :drop_share], {90, 5}))
    refute "enrichment_drops" in keys(put_in(base(), [:enrichment_queue, :drop_share], {0, 0}))
  end

  test "a queue that does not report the share yet (old build) stays quiet" do
    refute "enrichment_drops" in keys(put_in(base(), [:enrichment_queue], %{http_starved_streak: 0}))
  end

  test "the drop share is computed from what was sent, not what came back" do
    assert EnrichmentQueue.drop_share([]) == {0, 0}
    assert EnrichmentQueue.drop_share([{8, 8}, {8, 8}]) == {0, 2}
    assert EnrichmentQueue.drop_share([{8, 1}, {8, 0}, {8, 1}]) == {91, 3}
    assert EnrichmentQueue.drop_share([{0, 0}]) == {0, 1}
  end
end
