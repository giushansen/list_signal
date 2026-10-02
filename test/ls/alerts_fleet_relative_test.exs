defmodule LS.AlertsFleetRelativeTest do
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Ops.BackupLog

  @moduledoc """
  2026-10-02: eight "Worker down" emails and "Ingestion stalled" in one
  night while every worker was up and claiming batches. The data model v2
  work of 10-01 changed what a row means (filtered domains write none),
  paced the fleet to a fifth of its old volume, and redeployed every node
  eight to twelve times. Absolute floors chosen in August read a uniformly
  low fleet as eight dead nodes. A worker is down when it is far behind the
  fleet; ingestion is stalled when the queue stops draining.
  """

  defp healthy do
    %{
      ingestion_3h: 600_000,
      per_worker: for(i <- 1..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 180_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}),
      known_workers: for(i <- 1..8, do: "worker_n#{i}@10.0.0.#{i}"),
      stale_seconds: 200,
      worker_health: %{"worker_n1@10.0.0.1" => %{quarantined: false, ratio: 0.98, dropped: 0}},
      queue: %{queue_pct: 40.0, drain_rate_per_min: 4_000.0},
      node_resources: [{:"master@10.0.0.1", %{disk_used_pct: 60, disk_used_gb: 200, disk_total_gb: 361, mem_avail_mb: 8000}}],
      reputation_ages: %{tranco: 5, majestic: 6, blocklist: 3},
      backups: %{dir: "/home/ls/backups", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 20},
      enrichment_queue: %{http_starved_streak: 0},
      verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
      poller: nil,
      ctl_diff: %{new: [], retired: []},
      unmonitored_nodes: [],
      watchdog_restarts: [],
      data_check: %{quality: [], quantity: [], speed: []}
    }
  end

  defp keys(alerts), do: Enum.map(alerts, & &1.key)

  describe "worker down is relative to the fleet" do
    test "the 2026-10-02 night: the whole fleet under the August floor fires nothing" do
      pw = for i <- 1..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 15_000 + i * 300, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}
      a = Alerts.evaluate(%{healthy() | per_worker: pw})
      refute Enum.any?(keys(a), &String.starts_with?(&1, "worker_dead"))
    end

    test "one node at a quarter of the fleet median fires, even in a low fleet" do
      pw = [%{worker: "worker_n1@10.0.0.1", rows: 2_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}
            | for(i <- 2..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 16_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5})]
      a = Alerts.evaluate(%{healthy() | per_worker: pw})
      assert "worker_dead:worker_n1@10.0.0.1" in keys(a)
      assert Enum.count(keys(a), &String.starts_with?(&1, "worker_dead")) == 1
    end

    test "a node missing from the last six hours still fires against a healthy fleet" do
      a = Alerts.evaluate(%{healthy() | per_worker: Enum.drop(healthy().per_worker, 1)})
      assert "worker_dead:worker_n1@10.0.0.1" in keys(a)
    end

    test "the median helper is pure and survives a fleet of one or none" do
      live = %{"a" => 100, "b" => 5_000, "c" => 9_000}
      assert Alerts.fleet_median(["a", "b", "c"], live) == 5_000
      assert Alerts.fleet_median(["a"], live) > 0
      assert Alerts.fleet_median([], %{}) > 0
    end
  end

  describe "ingestion stalled needs a stalled queue" do
    test "low rows with a draining queue is a volume change, not a stall" do
      a = Alerts.evaluate(%{healthy() | ingestion_3h: 72_000, queue: %{queue_pct: 0.0, drain_rate_per_min: 390.0}})
      refute "ingestion_low" in keys(a)
    end

    test "low rows with a dead queue is a stall" do
      a = Alerts.evaluate(%{healthy() | ingestion_3h: 72_000, queue: %{queue_pct: 0.0, drain_rate_per_min: 12.0}})
      assert "ingestion_low" in keys(a)
    end

    test "low rows with no queue figure at all still fires, as before" do
      a = Alerts.evaluate(%{healthy() | ingestion_3h: 40_000, queue: %{queue_pct: 40.0}})
      assert "ingestion_low" in keys(a)
    end
  end

  describe "a backup run with an ERROR line is a failed run" do
    test "the 2026-09-27 shape: dump ok, ship failed, reads as :error" do
      log = """
      2026-09-27 03:15:01 [ch] === backup start (disk 63%) ===
      2026-09-27 03:39:31 [ch] clickhouse ok (44G)
      2026-09-27 03:39:31 [ch] WARN could not clear the previous offsite chw archive
      2026-09-27 03:39:31 [ch] ERROR offsite ship of chw_20260927_031501.tar failed; keeping the local copy
      2026-09-27 03:39:32 [ch] === backup done (disk 76%, 1 CH archives, 60 sqlite) ===
      """

      assert BackupLog.last_ch_result(log) == :error
    end

    test "a clean run still reads as :ok and a skipped run as :skipped" do
      assert BackupLog.last_ch_result("2026-10-04 03:15:01 [ch] === backup start (disk 60%) ===\n2026-10-04 03:40:00 [ch] clickhouse ok (46G)\n2026-10-04 04:30:00 [ch] clickhouse archive shipped offsite and removed locally\n") == :ok
      assert BackupLog.last_ch_result("2026-10-04 03:15:01 [ch] === backup start (disk 80%) ===\n2026-10-04 03:15:01 [ch] ERROR CH backup skipped: 60G free < 92G needed\n") == :skipped
    end
  end
end
