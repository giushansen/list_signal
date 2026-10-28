defmodule LS.AlertsBackupOffsiteTest do
  @moduledoc """
  2026-10-28: no product tar had reached the offsite box since 2026-10-16.
  Every 6-hourly ship failed on a full disk there, the local archive stayed
  fresh (the tar is made before the ship), the only alert was the weekly
  ClickHouse tier's, and the gap was found by looking. The ship's own
  success line in backup.log is now read and judged.
  """
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Ops.BackupLog

  @log """
  2026-10-27 18:30:01 [product] === backup start (disk 78%) ===
  2026-10-27 18:36:40 [product] product ok (19G)
  2026-10-27 18:36:41 [product]   offsite: removed prod_20261015_183001.tar to make room (28G free for a 19G tar)
  2026-10-27 18:52:10 [product]   offsite ok: prod_20261027_183001.tar
  2026-10-27 18:52:10 [product] === backup done (disk 78%, 0 CH archives, 60 sqlite) ===
  2026-10-28 00:30:01 [product] === backup start (disk 78%) ===
  2026-10-28 00:36:12 [product] product ok (20G)
  rsync: [sender] write error: Broken pipe (32)
  2026-10-28 00:38:52 [product] ERROR offsite ship failed: prod_20261028_003002.tar
  2026-10-28 01:00:01 [sqlite] === backup start (disk 78%) ===
  2026-10-28 01:00:01 [sqlite] sqlite ok (308K)
  2026-10-28 01:00:04 [sqlite]   offsite ok: sqlite_20261028_010001.db
  """

  describe "the log's newest successful product ship" do
    test "is the last 'offsite ok: prod_' line, whatever tier wrote it, and a failed ship after it does not count" do
      assert BackupLog.last_product_offsite_ok_at(@log) == "2026-10-27 18:52:10"
    end

    test "a later tier re-shipping the tar counts: the hourly sqlite run ships what the product run left" do
      log = @log <> "2026-10-28 02:00:03 [sqlite]   offsite ok: prod_20261028_003002.tar\n"
      assert BackupLog.last_product_offsite_ok_at(log) == "2026-10-28 02:00:03"
    end

    test "sqlite ships, ERROR lines and garbage are not a product ship" do
      assert BackupLog.last_product_offsite_ok_at("2026-10-28 01:00:04 [sqlite]   offsite ok: sqlite_20261028_010001.db\n") == nil
      assert BackupLog.last_product_offsite_ok_at("2026-10-28 00:38:52 [product] ERROR offsite ok: prod_x.tar never\n") == nil
      assert BackupLog.last_product_offsite_ok_at("") == nil
      assert BackupLog.last_product_offsite_ok_at(nil) == nil
    end
  end

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
      backups: %{dir: "/home/ls/backups", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 20, product_offsite_age_h: 5},
      enrichment_queue: %{http_starved_streak: 0},
      verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
      poller: nil,
      ctl_diff: %{new: [], retired: []},
      unmonitored_nodes: [],
      watchdog_restarts: [],
      data_check: %{quality: [], quantity: [], speed: []}
    }
  end

  defp offsite_alerts(m), do: Alerts.evaluate(m) |> Enum.filter(&String.starts_with?(&1.key, "backup_offsite_product"))

  describe "the alert" do
    test "a product tar that reached the offsite box five hours ago is silent" do
      assert offsite_alerts(healthy()) == []
    end

    test "fourteen hours without a ship is critical: the 6-hourly tier missed two runs" do
      [a] = offsite_alerts(%{healthy() | backups: Map.put(healthy().backups, :product_offsite_age_h, 15)})
      assert a.key == "backup_offsite_product"
      assert a.severity == :critical
      assert a.line =~ "the master holds the only copy"
      assert offsite_alerts(%{healthy() | backups: Map.put(healthy().backups, :product_offsite_age_h, 14)}) == []
    end

    test "a log with no successful ship at all is critical too, under the missing key" do
      [a] = offsite_alerts(%{healthy() | backups: Map.put(healthy().backups, :product_offsite_age_h, nil)})
      assert a.key == "backup_offsite_product_missing"
      assert a.severity == :critical
    end

    test "a metrics map without the key (older release, a worker) stays quiet" do
      assert offsite_alerts(%{healthy() | backups: Map.delete(healthy().backups, :product_offsite_age_h)}) == []
      assert offsite_alerts(%{healthy() | backups: %{dir: nil}}) == []
    end
  end
end
