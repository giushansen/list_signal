defmodule LS.AlertsSustainedTest do
  use ExUnit.Case, async: true

  alias LS.Alerts

  @moduledoc """
  10-02 and 10-03 by email: "1 node(s) report no resources" twice,
  "Ingestion rate" four times, "Ingestion stalled" three times (146.1K
  rows in 3 h against a 150K floor chosen in August, a rate window empty
  after a restart). None lasted fifteen minutes. A flappy key must hold
  across two ticks; a stall must be well under the fleet's own trailing
  day, with a queue that stops draining, on a master that is not booting.
  """

  defp healthy do
    %{
      ingestion_3h: 600_000,
      per_worker: for(i <- 1..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 180_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}),
      known_workers: for(i <- 1..8, do: "worker_n#{i}@10.0.0.#{i}"),
      stale_seconds: 200,
      worker_health: %{},
      queue: %{queue_pct: 40.0, drain_rate_per_min: 4_000.0, uptime_seconds: 86_400},
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

  describe "a stall is relative to the fleet's own day" do
    test "146K in 3h with a 1.2M day is the fleet's normal, not a stall" do
      m = Map.merge(healthy(), %{ingestion_3h: 146_100, ingestion_24h: 1_200_000, queue: %{queue_pct: 40.0, drain_rate_per_min: 0.0, uptime_seconds: 86_400}})
      refute "ingestion_low" in keys(m)
    end

    test "40K in 3h against a 1.2M day with a dead queue is a stall" do
      m = Map.merge(healthy(), %{ingestion_3h: 40_000, ingestion_24h: 1_200_000, queue: %{queue_pct: 40.0, drain_rate_per_min: 0.0, uptime_seconds: 86_400}})
      assert "ingestion_low" in keys(m)
    end

    test "a master that restarted ten minutes ago has an empty rate window and is not a stall" do
      m = Map.merge(healthy(), %{ingestion_3h: 40_000, ingestion_24h: 1_200_000, queue: %{queue_pct: 40.0, drain_rate_per_min: 0.0, uptime_seconds: 600}})
      refute "ingestion_low" in keys(m)
    end

    test "without a trailing day the August floor still applies, as before" do
      m = %{healthy() | ingestion_3h: 40_000, queue: %{queue_pct: 40.0, drain_rate_per_min: 0.0}}
      assert "ingestion_low" in keys(m)
    end
  end

  describe "flappy keys must hold across two ticks" do
    test "an unmonitored node or a volume dip seen once is held back, seen twice goes out" do
      raised = [%{key: "unmonitored:1"}, %{key: "data_quantity:changes recorded"}, %{key: "ingestion_low"}, %{key: "disk:master"}]
      assert Enum.map(Alerts.sustain(raised, []), & &1.key) == ["disk:master"]
      assert Enum.map(Alerts.sustain(raised, ["unmonitored:1", "ingestion_low"]), & &1.key) == ["unmonitored:1", "ingestion_low", "disk:master"]
    end

    test "a hard fault never waits" do
      raised = [%{key: "worker_dead:worker_n1@10.0.0.1"}, %{key: "backup_ch_run:2026-10-04"}, %{key: "enrichment_drops"}]
      assert Alerts.sustain(raised, []) == raised
      refute Alerts.flappy?("worker_dead:x")
      assert Alerts.flappy?("data_quantity:new businesses")
    end
  end
end
