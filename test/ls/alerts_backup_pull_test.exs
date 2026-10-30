defmodule LS.AlertsBackupPullTest do
  @moduledoc """
  2026-10-30: the owner asked for a copy of the product tables on h1 and on
  their own machine every day, and for proof that it happens. Both legs are
  pulls, so the master cannot see them: the h1 pull had silently held only
  sqlite files for a month (10-28) and the laptop pull had failed for 29
  days behind a healthy-looking launchd job. Each puller now writes
  `.pull_ok_<name>` on the master when its verified copy is complete, and
  the age of that marker is alerted on.
  """
  use ExUnit.Case, async: true

  alias LS.Alerts
  alias LS.Ops.BackupLog

  @now ~U[2026-10-30 03:00:00Z]

  describe "the marker" do
    test "is an ISO 8601 instant and reads as whole hours of age" do
      assert BackupLog.pull_marker_age_h("2026-10-30T01:35:59Z\n", @now) == 1
      assert BackupLog.pull_marker_age_h("2026-10-29T21:40:15Z", @now) == 5
      assert BackupLog.pull_marker_age_h("2026-10-28T02:59:59Z", @now) == 48
    end

    test "a marker from the future is fresh, never a negative age: three machines, three clocks" do
      assert BackupLog.pull_marker_age_h("2026-10-30T03:10:00Z", @now) == 0
    end

    test "garbage, an empty file and a missing file are nil, which the alert reports as missing" do
      assert BackupLog.pull_marker_age_h("pull done", @now) == nil
      assert BackupLog.pull_marker_age_h("", @now) == nil
      assert BackupLog.pull_marker_age_h("2026-10-30 01:35:59", @now) == nil
      assert BackupLog.pull_marker_age_h(nil, @now) == nil
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
      backups: %{
        dir: "/home/ls/backups",
        sqlite_age_h: 1,
        product_age_h: 3,
        ch_age_h: 20,
        product_offsite_age_h: 5,
        pull_ages_h: %{"h1" => 5, "laptop" => 1}
      },
      enrichment_queue: %{http_starved_streak: 0},
      verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
      poller: nil,
      ctl_diff: %{new: [], retired: []},
      unmonitored_nodes: [],
      watchdog_restarts: [],
      data_check: %{quality: [], quantity: [], speed: []}
    }
  end

  defp with_pulls(ages), do: %{healthy() | backups: Map.put(healthy().backups, :pull_ages_h, ages)}
  defp pull_alerts(m), do: Alerts.evaluate(m) |> Enum.filter(&String.starts_with?(&1.key, "backup_pull_"))

  describe "the alert" do
    test "both legs confirmed within a day is silent" do
      assert pull_alerts(healthy()) == []
    end

    test "h1 is always on and pulls nightly: 37 hours without a marker is critical, 36 is not" do
      [a] = pull_alerts(with_pulls(%{"h1" => 37, "laptop" => 1}))
      assert a.key == "backup_pull_h1"
      assert a.severity == :critical
      assert a.line =~ "h1 has not confirmed a verified copy"
      assert pull_alerts(with_pulls(%{"h1" => 36, "laptop" => 1})) == []
    end

    test "the laptop may be closed for a day: 49 hours is a warning, 48 is not" do
      [a] = pull_alerts(with_pulls(%{"h1" => 5, "laptop" => 49}))
      assert a.key == "backup_pull_laptop"
      assert a.severity == :warning
      assert pull_alerts(with_pulls(%{"h1" => 5, "laptop" => 48})) == []
    end

    test "a leg that never wrote a marker is reported as missing at the leg's severity" do
      keys = pull_alerts(with_pulls(%{})) |> Enum.map(&{&1.key, &1.severity}) |> Enum.sort()
      assert keys == [{"backup_pull_h1_missing", :critical}, {"backup_pull_laptop_missing", :warning}]
      [a] = pull_alerts(with_pulls(%{"h1" => 2, "laptop" => nil}))
      assert a.key == "backup_pull_laptop_missing"
    end

    test "a metrics map without the key (older release, a worker, no backup dir) stays quiet" do
      assert pull_alerts(%{healthy() | backups: Map.delete(healthy().backups, :pull_ages_h)}) == []
      assert pull_alerts(%{healthy() | backups: %{dir: nil}}) == []
    end
  end
end
