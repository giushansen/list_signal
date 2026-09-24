defmodule LS.AlertsBackupOnceAndOffsiteAgeTest do
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Ops.BackupLog

  @moduledoc """
  2026-09-24, two follow-ups to the backup alerting.

  A failed ClickHouse run stays the newest run in the log until the next
  scheduled one, a week later now that the dump is weekly; with the
  ordinary 6-hour cooldown the same failure would be emailed 28 times. A
  dated key is a single unrepeatable event and dedups forever, like a
  watchdog restart. And since the archive ships offsite and is removed
  locally, "no chw_*.tar on disk" is the normal state: the age of the last
  dump comes from the log's last "clickhouse ok" line instead.
  """

  test "a dated backup-run key dedups forever; the undated one keeps the cooldown" do
    assert Alerts.permanent_dedup?("backup_ch_run:2026-09-23")
    refute Alerts.permanent_dedup?("backup_ch_run")
    refute Alerts.permanent_dedup?("backup_ch")
  end

  test "the last successful ch run's time is read from the log, newest wins" do
    log = """
    2026-09-13 03:15:01 [ch] === backup start (disk 70%) ===
    2026-09-13 03:33:00 [ch] clickhouse ok (41G)
    2026-09-20 03:15:01 [ch] === backup start (disk 78%) ===
    2026-09-20 03:31:33 [ch] clickhouse ok (42G)
    2026-09-23 03:15:01 [ch] === backup start (disk 78%) ===
    2026-09-23 03:31:45 [ch] ERROR clickhouse tar failed; removing partial archive
    """

    assert BackupLog.last_ch_ok_at(log) == "2026-09-20 03:31:33"
    assert BackupLog.last_ch_ok_at("2026-09-23 03:15:01 [sqlite] sqlite ok (252K)\n") == nil
    assert BackupLog.last_ch_ok_at(nil) == nil
  end
end
