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
      backups: %{dir: "/home/ls/backups", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 20},
      verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
      poller: nil,
      ctl_diff: %{new: [], retired: []},
      unmonitored_nodes: [],
      watchdog_restarts: [],
      data_check: %{quality: [], quantity: [], speed: []}
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

  test "each backup tier alerts at its own cadence, severity by rebuild cost" do
    # backup.sh tiers: sqlite hourly, product 4x/day, ClickHouse weekly.
    stale = Alerts.evaluate(%{healthy() | backups: %{dir: "/b", sqlite_age_h: 9, product_age_h: 30, ch_age_h: 400}})
    assert Enum.any?(stale, &(&1.key == "backup_product" and &1.severity == :critical)), "product = weeks of crawling"
    assert Enum.any?(stale, &(&1.key == "backup_sqlite" and &1.severity == :critical)), "sqlite = irreplaceable"
    assert Enum.any?(stale, &(&1.key == "backup_ch" and &1.severity == :warning)), "CH = weekly history dump"
  end

  test "a tier with no archive at all is reported as missing, not merely stale" do
    none = Alerts.evaluate(%{healthy() | backups: %{dir: "/b", sqlite_age_h: 1, product_age_h: nil, ch_age_h: 20}})
    assert Enum.any?(none, &(&1.key == "backup_product_missing" and &1.severity == :critical))
  end

  test "a weekly ClickHouse dump 20h old is NOT stale (its cadence is 7 days)" do
    # Regression: an earlier version used a 60h ceiling meant for a daily job
    # and would have paged every week on a healthy weekly backup.
    a = Alerts.evaluate(%{healthy() | backups: %{dir: "/b", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 170}})
    refute Enum.any?(a, &String.starts_with?(&1.key, "backup_"))
  end

  test "SEAM: every tier LS.Metrics reports is a tier LS.Alerts reads" do
    # 2026-08-24: alerts.ex was changed to read b[:product_age_h] while the
    # matching metrics.ex edit silently never persisted, so the key was ALWAYS
    # nil and the owner got "No product backup exists" every 6h while backups
    # were fine. The unit tests passed because evaluate/1 is pure and was fed a
    # hand-built map — nothing pinned the Metrics->Alerts seam. This does.
    keys = LS.Metrics.backup_status("/nonexistent-#{System.unique_integer([:positive])}") |> Map.keys()
    assert :dir in keys
    for tier <- LS.Metrics.backup_tiers(), do: assert(tier in keys, "backup_status must report #{tier}")

    src = File.read!("lib/ls/alerts.ex")
    for tier <- LS.Metrics.backup_tiers() do
      assert src =~ "b[:#{tier}]", "LS.Alerts must read #{tier}"
    end

    # The direction that actually bit: LS.Alerts reading a key LS.Metrics never
    # sets. Such a key is silently nil forever, which this alerter reports as
    # "no backup exists" — a false critical every cooldown window.
    read_by_alerts =
      Regex.scan(~r/b\[:(\w+_age_h)\]/, src) |> Enum.map(&List.last/1) |> Enum.uniq() |> Enum.map(&String.to_atom/1)

    for key <- read_by_alerts do
      assert key in LS.Metrics.backup_tiers(),
             "LS.Alerts reads b[:#{key}] but LS.Metrics.backup_status/0 never sets it — it will always be nil"
    end
  end

  test "a machine with no backup directory reports nothing (not three missing backups)" do
    a = Alerts.evaluate(%{healthy() | backups: %{dir: nil, sqlite_age_h: nil, product_age_h: nil, ch_age_h: nil}})
    refute Enum.any?(a, &String.starts_with?(&1.key, "backup_"))
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
  describe "data checks flow into the same digest (2026-08-28)" do
    test "a broken data metric raises through evaluate/1 like any infra alert" do
      snap = %{
        quality: [%{label: "country", kind: :fill, recent: 40.0, base: 85.0, band: :error}],
        quantity: [],
        speed: []
      }

      a = Alerts.evaluate(%{healthy() | data_check: snap})
      found = Enum.find(a, &(&1.key == "data_quality:country"))

      assert found
      assert found.severity == :critical
      assert found.line =~ "85.0%"
    end

    test "a green data snapshot adds nothing" do
      assert Alerts.evaluate(healthy()) |> Enum.filter(&String.starts_with?(&1.key, "data_")) == []
    end
  end

  describe "a silent auto-recovery is still an outage (2026-08-27)" do
    # The site was down 07:30-07:46 local; the watchdog restarted it and NOTHING
    # told the owner, because alerting runs inside the process that died. The
    # same BEAM stall had already recurred on 08-21, 08-22 and twice on 08-26
    # without anyone noticing. Silence after a restart must never read as uptime.
    test "a watchdog restart raises a critical alert naming when it happened" do
      at = ~U[2026-08-26 23:32:09Z]
      a = Alerts.evaluate(%{healthy() | watchdog_restarts: [%{at: at, line: "web dead after 3 probes"}]})
      found = Enum.find(a, &String.starts_with?(&1.key, "watchdog_restart"))

      assert found, "an auto-restart means the site was down — it must alert"
      assert found.severity == :critical
      assert found.line =~ "2026-08-26 23:32:09"
    end

    test "several restarts in a day are reported as a count, not one per restart" do
      restarts = for h <- [1, 5, 9], do: %{at: DateTime.add(~U[2026-08-26 23:32:09Z], -h * 3600), line: "x"}
      a = Alerts.evaluate(%{healthy() | watchdog_restarts: restarts})

      assert Enum.count(a, &String.starts_with?(&1.key, "watchdog_restart")) == 1
      assert Enum.find(a, &String.starts_with?(&1.key, "watchdog_restart")).subject =~ "3x"
    end

    test "no restarts is silence" do
      assert Alerts.evaluate(healthy()) |> Enum.find(&String.starts_with?(&1.key, "watchdog_restart")) == nil
    end

    test "a missing key does not crash evaluate/1" do
      assert is_list(Alerts.evaluate(Map.delete(healthy(), :watchdog_restarts)))
    end
  end

  describe "unmonitored nodes are themselves an alert (2026-08-26)" do
    # 12 of 14 workers had been restarted but never re-deployed since the ops
    # tooling shipped, so LS.Ops.NodeResources was :undef on them and the
    # master could only read memory from the two newest nodes. The owner spent
    # two days believing chi3/ny3 had a memory fault; they were simply the only
    # nodes being watched. Silence must never look like health again.
    test "nodes reporting no resources produce a warning naming them" do
      alerts =
        Alerts.evaluate(%{
          healthy()
          | unmonitored_nodes: [:"worker_lssg1@10.0.0.3", :"worker_lschi1@10.0.0.11"]
        })

      a = Enum.find(alerts, &(&1.key =~ "unmonitored"))
      assert a, "a blind spot in resource monitoring must raise an alert"
      assert a.line =~ "lssg1"
      assert a.line =~ "lschi1"
      assert a.line =~ "stale release"
    end

    test "a fully-monitored fleet raises nothing" do
      assert Alerts.evaluate(healthy()) |> Enum.find(&(&1.key =~ "unmonitored")) == nil
    end

    test "a snapshot without the key at all does not crash (older gather/0 in flight during a deploy)" do
      assert is_list(Alerts.evaluate(Map.delete(healthy(), :unmonitored_nodes)))
    end
  end

  describe "PSI memory-pressure danger signal (2026-08-30)" do
    # The old check fired on raw % available, which could not tell "swap in
    # use, running fine" from "system is thrashing" — workers were found to
    # run with no memory limit and swap freely, so raw-% alone was noise.
    # PSI's `full` line measures actual stall time, the real danger signal.
    test "high memory usage with low PSI stays silent — this is the noise the redesign removes" do
      r = %{mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.1, mem_avail_mb: 50, mem_total_mb: 2_000}
      a = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]})
      refute Enum.any?(a, &String.starts_with?(&1.key, "mem"))
    end

    test "sustained stall over 60s is a warning" do
      assert Alerts.mem_pressure_band(0.5, 6.0) == :warning
    end

    test "an acute 10s stall is critical even if the 60s average looks fine" do
      assert Alerts.mem_pressure_band(20.0, 1.0) == :critical
    end

    test "below both thresholds is quiet" do
      assert Alerts.mem_pressure_band(2.0, 1.0) == :ok
    end

    test "no PSI at all reports :unknown so the caller can fall back, not silently skip" do
      assert Alerts.mem_pressure_band(nil, nil) == :unknown
    end

    test "a warning-level stall does NOT email — 2026-08-30 owner instruction" do
      # par2 and sg2 both sat under 2% (well below even this 7.5% test value)
      # when a :warning fired in production and neither node was in any real
      # trouble. "If it is not about to crash don't send me email for these
      # nodes." Only :critical emails now; :warning is logged, not alerted.
      r = %{mem_pressure_full_avg10: 1.0, mem_pressure_full_avg60: 7.5, mem_avail_mb: 500, mem_total_mb: 4_000}
      a = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]})
      refute Enum.any?(a, &String.starts_with?(&1.key, "mem_pressure"))
    end

    test "a single critical tick does not email; the SAME node critical next tick does" do
      # 2026-09-05: thrashing emails arrived several times a day from a
      # rotating cast of workers, each a transient swap storm that dented one
      # node ~15-25% for 15-30 min and self-recovered (~0.2% of a fleet-day).
      # A stall only earns an email once it survives into the next 15-minute
      # check; the isolated spike is log-and-weekly-report material.
      :persistent_term.erase({LS.Alerts, :psi_critical_at})
      on_exit(fn -> :persistent_term.erase({LS.Alerts, :psi_critical_at}) end)

      r = %{mem_pressure_full_avg10: 22.0, mem_pressure_full_avg60: 9.0, mem_avail_mb: 300, mem_total_mb: 4_000}
      m = %{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]}

      first = Alerts.evaluate(m)
      refute Enum.any?(first, &String.starts_with?(&1.key, "mem_pressure")),
             "first critical tick must be logged, not emailed"

      second = Alerts.evaluate(m)
      assert Enum.any?(second, &String.starts_with?(&1.key, "mem_pressure")),
             "still critical on the next tick is a sustained stall and must email"
    end

    test "two isolated spikes far apart never combine into a sustained alert" do
      :persistent_term.erase({LS.Alerts, :psi_critical_at})
      on_exit(fn -> :persistent_term.erase({LS.Alerts, :psi_critical_at}) end)

      r = %{mem_pressure_full_avg10: 22.0, mem_pressure_full_avg60: 9.0, mem_avail_mb: 300, mem_total_mb: 4_000}
      m = %{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]}
      Alerts.evaluate(m)

      # Age the marker past the 35-minute sustained window, as if the node
      # recovered and spiked again hours later.
      stale = System.system_time(:millisecond) - :timer.minutes(40)
      :persistent_term.put({LS.Alerts, :psi_critical_at}, %{:"worker_n1@10.0.0.1" => stale})

      later = Alerts.evaluate(m)
      refute Enum.any?(later, &String.starts_with?(&1.key, "mem_pressure")),
             "a spike 40 minutes after the last one is a fresh first tick, not a sustained stall"
    end

    test "a sustained critical fires as :critical and names the real cost" do
      :persistent_term.erase({LS.Alerts, :psi_critical_at})
      on_exit(fn -> :persistent_term.erase({LS.Alerts, :psi_critical_at}) end)

      r = %{mem_pressure_full_avg10: 18.0, mem_pressure_full_avg60: 12.0, mem_avail_mb: 100, mem_total_mb: 2_000}
      m = %{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]}
      # First tick arms the sustained marker (2026-09-05 rule); the second is the send.
      Alerts.evaluate(m)
      a = Alerts.evaluate(m)
      found = Enum.find(a, &(&1.key == "mem_pressure:worker_n1@10.0.0.1"))
      assert found.severity == :critical
      assert found.line =~ "18.0%"
      assert found.line =~ "two consecutive checks", "the email must say the stall is sustained, not a blip"
    end

    test "a node with no PSI falls back to the old raw-% check, not silence" do
      r = %{mem_pressure_full_avg10: nil, mem_pressure_full_avg60: nil, mem_avail_mb: 50, mem_total_mb: 2_000}
      a = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]})
      assert Enum.any?(a, &(&1.key == "mem:worker_n1@10.0.0.1"))
    end

    test "a node with no PSI and healthy raw-% stays fully silent" do
      r = %{mem_pressure_full_avg10: nil, mem_pressure_full_avg60: nil, mem_avail_mb: 1_500, mem_total_mb: 2_000}
      a = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]})
      assert a == []
    end
  end

  describe "restart-reason alert (2026-08-30)" do
    test "a clean 'success' restart is silent — this is what a deploy looks like" do
      r = %{restart_result: "success", restart_count: 5, mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.0}
      a = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]})
      refute Enum.any?(a, &String.starts_with?(&1.key, "restart_reason"))
    end

    test "an oom-kill fires critical, naming the node and the reason" do
      r = %{restart_result: "oom-kill", restart_count: 3, mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.0}
      a = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]})
      found = Enum.find(a, &String.starts_with?(&1.key, "restart_reason"))

      assert found
      assert found.severity == :critical
      assert found.line =~ "oom-kill"
    end

    test "the SAME restart is reported once — no re-alert on every 15-minute tick" do
      r = %{restart_result: "oom-kill", restart_count: 3, mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.0}
      key1 = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]}) |> hd() |> Map.get(:key)
      key2 = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]}) |> hd() |> Map.get(:key)
      assert key1 == key2, "identical restart_count must produce the identical alert key so cooldown dedups it"
    end

    test "a NEW restart (incremented count) is a fresh, distinct key" do
      r1 = %{restart_result: "oom-kill", restart_count: 3, mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.0}
      r2 = %{r1 | restart_count: 4}
      k1 = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r1}]}) |> hd() |> Map.get(:key)
      k2 = Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r2}]}) |> hd() |> Map.get(:key)
      refute k1 == k2
    end

    test "permanent_dedup?/1 marks watchdog restarts and restart reasons as forever-dedup" do
      # A restart's own key stays identical for as long as no NEW restart
      # happens, so it must never re-fire on the ordinary 6h cooldown: found
      # 2026-08-30 as one real master restart producing two identical emails
      # 6h9m apart, because the 6h window had simply lapsed on the SAME key.
      assert Alerts.permanent_dedup?("watchdog_restart:1788067089")
      assert Alerts.permanent_dedup?("restart_reason:worker_n1@10.0.0.1:3")
    end

    test "permanent_dedup?/1 leaves every other alert on the ordinary rolling cooldown" do
      refute Alerts.permanent_dedup?("mem_pressure:worker_n1@10.0.0.1")
      refute Alerts.permanent_dedup?("disk:master@10.0.0.1")
      refute Alerts.permanent_dedup?("ingestion_low")
      refute Alerts.permanent_dedup?("")
    end

    test "missing or nil restart info never raises" do
      r = %{mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.0}
      assert is_list(Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r}]}))

      r2 = %{restart_result: nil, restart_count: nil, mem_pressure_full_avg10: 0.0, mem_pressure_full_avg60: 0.0}
      assert Alerts.evaluate(%{healthy() | node_resources: [{:"worker_n1@10.0.0.1", r2}]}) == []
    end
  end

  describe "size-aware low-memory floor (2026-08-25)" do
    # The 900MB floor was written for the 16G master but applied to every
    # node. 250-350MB available is the healthy STEADY STATE of a busy 2G
    # worker, so the first workers to report memory (chi3/ny3) emailed "Low
    # memory" from their normal operation — an alert that cries wolf trains
    # the owner to ignore the real one.
    test "the MEASURED healthy range of a 1-core crawler (205-373MB) does not alert" do
      floor = Alerts.mem_floor_mb(1_968)
      # Real readings from sg1/syd1/chi3/ny3 on 2026-08-26.
      for avail <- [205, 223, 257, 296, 342, 373] do
        assert avail > floor, "#{avail}MB is a healthy steady state, not an alert"
      end
    end

    test "a 2G worker in genuine distress still alerts" do
      assert 80 < Alerts.mem_floor_mb(1_968)
    end

    test "the 4G floor sits where real thrashing was observed (chi1/ny2 at 241-277MB)" do
      floor = Alerts.mem_floor_mb(3_916)
      assert floor == 195
      # Those nodes were swapping thousands of pages/sec; a further dip must alert.
      assert floor < 241
    end

    test "the 16G master keeps a meaningful floor" do
      assert Alerts.mem_floor_mb(15_993) == 799
    end

    test "a node that did not report its total falls back to the old conservative floor" do
      assert Alerts.mem_floor_mb(nil) == 900
      assert Alerts.mem_floor_mb("garbage") == 900
      assert Alerts.mem_floor_mb(0) == 900
    end
  end
end
