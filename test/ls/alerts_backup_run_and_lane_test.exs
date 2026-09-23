defmodule LS.AlertsBackupRunAndLaneTest do
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Ops.BackupLog

  @moduledoc """
  Two blind spots found on 2026-09-23.

  The nightly ClickHouse dump had failed four nights out of five, each
  failure filling the master's disk to 100% for sixteen minutes, and the
  archive-age alert saw a three-day-old archive as fine. Pipeline 2 ran at a
  third of its rate for two weeks while the row-count alert stayed quiet,
  because the browser lane kept the count above its floor. Both now alert
  on the direct signal: the backup run's own verdict, and the HTTP lane's
  refill starvation streak.
  """

  @log """
  2026-09-22 03:15:01 [ch] === backup start (disk 77%) ===
  tar: /home/ls/backups/chw_20260922_031501.tar: Cannot write: No space left on device
  2026-09-22 03:31:50 [ch] ERROR clickhouse tar failed; removing partial archive
  2026-09-22 03:31:52 [ch] === backup done (disk 77%, 1 CH archives, 60 sqlite) ===
  2026-09-22 04:00:01 [sqlite] === backup start (disk 77%) ===
  2026-09-22 04:00:01 [sqlite] sqlite ok (252K)
  """

  describe "the backup log's verdict" do
    test "a failed night reads as :error even when later sqlite runs succeeded" do
      assert BackupLog.last_ch_result(@log) == :error
    end

    test "a later successful run outranks an earlier failure" do
      assert BackupLog.last_ch_result(@log <> "2026-09-23 03:15:01 [ch] === backup start (disk 74%) ===\n2026-09-23 03:33:00 [ch] clickhouse ok (42G)\n") == :ok
    end

    test "a skipped run (not enough space) reads as :skipped" do
      assert BackupLog.last_ch_result("2026-09-24 03:15:01 [ch] === backup start (disk 80%) ===\n2026-09-24 03:15:01 [ch] ERROR CH backup skipped: 60G free < 92G needed\n") == :skipped
    end

    test "no ch run at all is nil, and garbage is nil" do
      assert BackupLog.last_ch_result("2026-09-22 04:00:01 [sqlite] sqlite ok (252K)\n") == nil
      assert BackupLog.last_ch_result(nil) == nil
    end
  end

  # A complete, healthy metrics map: evaluate/1 pattern-matches every key.
  defp healthy do
    %{
      ingestion_3h: 600_000,
      per_worker: for(i <- 1..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 180_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}),
      known_workers: for(i <- 1..8, do: "worker_n#{i}@10.0.0.#{i}"),
      stale_seconds: 200,
      worker_health: %{"worker_n1@10.0.0.1" => %{quarantined: false, ratio: 0.98, dropped: 0}},
      queue: %{queue_pct: 40.0},
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

  describe "alerts" do
    test "the healthy map with the two new keys still fires nothing" do
      assert Alerts.evaluate(healthy()) == []
    end

    test "a failed or skipped ClickHouse run is critical; ok and unknown are silent" do
      for {result, expect} <- [{:error, true}, {:skipped, true}, {:ok, false}, {nil, false}] do
        m = %{healthy() | backups: Map.put(healthy().backups, :ch_last_run, result)}
        assert Enum.any?(Alerts.evaluate(m), &(&1.key == "backup_ch_run" and &1.severity == :critical)) == expect, "result #{inspect(result)}"
      end

      # A metrics map from before this check carries no verdict; that stays quiet.
      refute Enum.any?(Alerts.evaluate(healthy()), &(&1.key == "backup_ch_run"))
    end

    test "six starved refills in a row page; five do not; an unreachable queue never does" do
      assert Enum.any?(Alerts.evaluate(%{healthy() | enrichment_queue: %{http_starved_streak: 6}}), &(&1.key == "enrichment_http_starved" and &1.severity == :critical))
      refute Enum.any?(Alerts.evaluate(%{healthy() | enrichment_queue: %{http_starved_streak: 5}}), &(&1.key == "enrichment_http_starved"))
      refute Enum.any?(Alerts.evaluate(%{healthy() | enrichment_queue: nil}), &(&1.key == "enrichment_http_starved"))
    end
  end

  describe "the starvation streak itself" do
    test "counts refills that fill under a quarter of real room, and resets on a healthy one" do
      alias LS.Cluster.EnrichmentQueue, as: Q
      assert Q.starved_streak(0, 3_500, 227) == 1
      assert Q.starved_streak(1, 3_500, 125) == 2
      assert Q.starved_streak(2, 3_500, 3_500) == 0, "a full refill ends the streak"
      assert Q.starved_streak(2, 400, 0) == 0, "a nearly full bucket is not starvation"
      assert Q.starved_streak(0, 1_000, 250) == 0, "a quarter is the line"
    end
  end
end
