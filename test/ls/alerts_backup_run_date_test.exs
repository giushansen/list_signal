defmodule LS.AlertsBackupRunDateTest do
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Ops.BackupLog

  @moduledoc """
  2026-09-24: the "ClickHouse backup failed last night" alert for the
  09-23 failure was emailed three times (08:12, 14:12, 20:27) because its
  key had no date, so every cooldown expiry re-sent the same fact. The key
  now carries the run's start date from backup.sh's log: one failed run,
  one email; a run without a readable start time keeps the undated key.
  """

  @log """
  2026-09-22 03:15:01 [ch] === backup start (disk 77%) ===
  2026-09-22 03:31:50 [ch] ERROR clickhouse tar failed; removing partial archive
  2026-09-22 03:31:52 [ch] === backup done (disk 77%, 1 CH archives, 60 sqlite) ===
  """

  test "the log's newest ch run carries its start time" do
    assert BackupLog.last_ch_run(@log) == %{result: :error, started_at: "2026-09-22 03:15:01"}
    assert BackupLog.last_ch_run("nothing here") == nil
    assert BackupLog.last_ch_run(nil) == nil
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

  test "a dated failure is keyed by its date, so two nights are two alerts and one night is one" do
    b = healthy().backups |> Map.put(:ch_last_run, :error) |> Map.put(:ch_last_run_at, "2026-09-23 03:15:01")
    keys = Alerts.evaluate(%{healthy() | backups: b}) |> Enum.map(& &1.key)
    assert "backup_ch_run:2026-09-23" in keys
    refute "backup_ch_run" in keys

    b2 = Map.put(b, :ch_last_run_at, "2026-09-24 03:15:01")
    assert "backup_ch_run:2026-09-24" in (Alerts.evaluate(%{healthy() | backups: b2}) |> Enum.map(& &1.key))
  end

  test "a failure without a readable start time keeps the undated key" do
    b = Map.put(healthy().backups, :ch_last_run, :error)
    assert "backup_ch_run" in (Alerts.evaluate(%{healthy() | backups: b}) |> Enum.map(& &1.key))
  end
end
