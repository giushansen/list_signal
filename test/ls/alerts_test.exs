defmodule LS.AlertsTest do
  @moduledoc "The alert judgement is pure, so its thresholds are pinned here without a cluster."
  use ExUnit.Case, async: true
  alias LS.Alerts

  # A healthy snapshot — nothing should fire.
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
      backups: %{sqlite_age_h: 1, ch_age_h: 20, ch_archives: 3, partial_archives: 0},
      verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
      poller: nil,
      ctl_diff: %{new: [], retired: []}
    }
  end

  defp keys(alerts), do: alerts |> Enum.map(& &1.key) |> Enum.sort()

  test "a healthy snapshot fires nothing (silence == healthy)" do
    assert Alerts.evaluate(healthy()) == []
  end

  test "stalled ingestion is critical" do
    a = Alerts.evaluate(%{healthy() | ingestion_3h: 40_000})
    assert Enum.any?(a, &(&1.key == "ingestion_low" and &1.severity == :critical))
  end

  test "a worker that went dark fires per-worker, others stay quiet" do
    pw = [%{worker: "worker_dead@10.0.0.9", rows: 500, http_ok_pct: 20.0, resolved_fail_pct: 6.0, classified_pct: 8.0} | Enum.drop(healthy().per_worker, 1)]
    known = ["worker_dead@10.0.0.9" | Enum.drop(healthy().known_workers, 1)]
    a = Alerts.evaluate(%{healthy() | per_worker: pw, known_workers: known})
    assert "worker_dead:worker_dead@10.0.0.9" in keys(a)
    assert Enum.count(a, &String.starts_with?(&1.key, "worker_dead")) == 1
  end

  test "a transient worker excluded from known_workers is never alerted (no false 'down')" do
    # LS.Metrics.known_workers floors on recent volume, so a one-off node is
    # simply absent from the expected set — evaluate/1 must not invent it.
    m = %{healthy() | known_workers: healthy().known_workers}  # transient not present
    a = Alerts.evaluate(m)
    refute Enum.any?(a, &String.starts_with?(&1.key, "worker_dead"))
  end

  test "the h1 split-brain signature (resolves DNS, HTTP fails) fires — but only above a sample floor" do
    hot = %{worker: "worker_h1@10.0.0.7", rows: 100_000, http_ok_pct: 2.0, resolved_fail_pct: 95.0, classified_pct: 1.0}
    tiny = %{worker: "worker_new@10.0.0.8", rows: 200, http_ok_pct: 2.0, resolved_fail_pct: 95.0, classified_pct: 1.0}
    a = Alerts.evaluate(%{healthy() | per_worker: [hot, tiny | Enum.drop(healthy().per_worker, 2)], known_workers: healthy().known_workers})
    assert "worker_quality:worker_h1@10.0.0.7" in keys(a)
    refute "worker_quality:worker_new@10.0.0.8" in keys(a), "a 200-row sample is too small to judge"
  end

  test "a quarantined worker and a frozen compactor are critical" do
    m = %{healthy() | worker_health: %{"w@1" => %{quarantined: true, ratio: 0.2, dropped: 5000}}, stale_seconds: 9_000}
    a = Alerts.evaluate(m)
    assert "quarantined" in keys(a)
    assert "compaction_stale" in keys(a)
    assert Enum.all?(a, &(&1.severity == :critical))
  end

  test "disk almost full is critical, low RAM is a warning" do
    m = %{healthy() | node_resources: [{:"master@1", %{disk_used_pct: 91, disk_used_gb: 330, disk_total_gb: 361, mem_avail_mb: 500}}]}
    a = Alerts.evaluate(m)
    assert Enum.any?(a, &(&1.key == "disk:master@1" and &1.severity == :critical))
    assert Enum.any?(a, &(&1.key == "mem:master@1" and &1.severity == :warning))
  end

  test "stale reputation downloads and a failed verification source warn" do
    m = %{healthy() | reputation_ages: %{tranco: 80, majestic: 6, blocklist: 3},
          verification: %{scheduler: %{running: false}, sources: [%{source: "sec_edgar", status: "error", duration_s: 0, error: "boom"}]}}
    a = Alerts.evaluate(m)
    assert "reputation:tranco" in keys(a)
    assert "verify_error:sec_edgar" in keys(a)
  end

  test "an unbacked or stale ClickHouse backup is critical (Aug 2026: disk bloat silently skipped it)" do
    missing = Alerts.evaluate(%{healthy() | backups: %{sqlite_age_h: 1, ch_age_h: nil, ch_archives: 0, partial_archives: 1}})
    assert Enum.any?(missing, &(&1.key == "backup_ch_missing" and &1.severity == :critical))
    assert Enum.any?(missing, &(&1.key == "backup_partial" and &1.severity == :warning))

    stale = Alerts.evaluate(%{healthy() | backups: %{sqlite_age_h: 9, ch_age_h: 200, ch_archives: 1, partial_archives: 0}})
    assert Enum.any?(stale, &(&1.key == "backup_ch_stale" and &1.severity == :critical))
    assert Enum.any?(stale, &(&1.key == "backup_sqlite_stale" and &1.severity == :warning))
  end

  test "disk warns early at 80% so backups keep their headroom, criticals at 88%" do
    warn = Alerts.evaluate(%{healthy() | node_resources: [{:"master@1", %{disk_used_pct: 83, disk_used_gb: 300, disk_total_gb: 361, mem_avail_mb: 8000}}]})
    assert Enum.any?(warn, &(&1.key == "disk_warn:master@1" and &1.severity == :warning))
    refute Enum.any?(warn, &(&1.key == "disk:master@1"))

    crit = Alerts.evaluate(%{healthy() | node_resources: [{:"master@1", %{disk_used_pct: 93, disk_used_gb: 330, disk_total_gb: 361, mem_avail_mb: 8000}}]})
    assert Enum.any?(crit, &(&1.key == "disk:master@1" and &1.severity == :critical))
    refute Enum.any?(crit, &(&1.key == "disk_warn:master@1")), "one disk alert at a time, not both"
  end

  test "CT-source changes surface: new = warning, retired = warning" do
    m = %{healthy() | ctl_diff: %{new: ["Sectigo 'Tiger2026h2'"], retired: ["Google Argon 2026h1"]}}
    a = Alerts.evaluate(m)
    assert Enum.any?(a, &(String.starts_with?(&1.key, "ctl_new") and &1.severity == :warning))
    assert Enum.any?(a, &(String.starts_with?(&1.key, "ctl_retired") and &1.severity == :warning))
  end

  test "critical alerts sort before warnings" do
    m = %{healthy() | ingestion_3h: 10_000, reputation_ages: %{tranco: 99, majestic: 6, blocklist: 3}}
    a = Alerts.evaluate(m)
    assert hd(a).severity == :critical
  end
end
