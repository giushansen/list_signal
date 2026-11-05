defmodule LS.AlertsClickhouseLogTest do
  use ExUnit.Case, async: true

  alias LS.{Alerts, Metrics}

  @moduledoc """
  2026-10-28 to 2026-11-04: the master's ClickHouse stopped writing its log
  file when the disk hit 97% and never recovered (Poco's file channel stays
  broken after one failed write). Every later log line became a "Cannot log
  message" stack trace on stderr: 170K lines an hour into journald for seven
  days, a CPU core in journald, the master at load 3.2 on 4 cores, the
  journal's retention down to eleven hours. Third time (2026-08-22 and
  2026-09-23 were the same) and every time it was found by someone reading
  the journal by hand. The failure sits between ClickHouse and journald,
  where no app metric looks, so a root cron counts it from the journal and
  leaves one line in /var/log/listsignal_ch_log_status for the sentinel.
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
      clickhouse_log: nil,
      data_check: %{quality: [], quantity: [], speed: []}
    }
  end

  defp ch_keys(m), do: m |> Alerts.evaluate() |> Enum.map(& &1.key) |> Enum.filter(&String.starts_with?(&1, "clickhouse_log"))
  defp status(over), do: Map.merge(%{at: DateTime.utc_now(), age_s: 60, storm_5m: 0, lines_5m: 40, journald_cpu_pct: 1}, over)

  test "a quiet, fresh status line raises nothing" do
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{}))) == []
  end

  test "no status file (laptop, workers) and a missing key raise nothing" do
    assert ch_keys(base()) == []
    assert ch_keys(Map.delete(base(), :clickhouse_log)) == []
  end

  test "one 'Cannot log message' line in five minutes is critical: the channel never recovers alone" do
    m = Map.put(base(), :clickhouse_log, status(%{storm_5m: 1}))
    [a] = Enum.filter(Alerts.evaluate(m), &(&1.key == "clickhouse_log_storm"))
    assert a.severity == :critical
    assert a.line =~ "Restart clickhouse-server"
    assert a.line =~ "2026-10-28"
  end

  test "a status line older than twenty minutes means the cron is dead, which hides the next storm" do
    m = Map.put(base(), :clickhouse_log, status(%{age_s: 21 * 60}))
    [a] = Enum.filter(Alerts.evaluate(m), &(&1.key == "clickhouse_log_check_stale"))
    assert a.severity == :warning
    assert a.line =~ "21 minutes old"

    # Stale wins over whatever the old line said: it is not current data.
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{age_s: 3 * 3600, storm_5m: 500}))) == ["clickhouse_log_check_stale"]
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{age_s: 19 * 60}))) == []
  end

  test "a flood from any cause (lines or journald CPU) is a warning, a normal volume is not" do
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{lines_5m: 2_001}))) == ["clickhouse_log_volume"]
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{journald_cpu_pct: 26}))) == ["clickhouse_log_volume"]
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{lines_5m: 2_000, journald_cpu_pct: 25}))) == []
    # The storm is the sharper diagnosis and is reported on its own.
    assert ch_keys(Map.put(base(), :clickhouse_log, status(%{storm_5m: 9_000, lines_5m: 100_000, journald_cpu_pct: 49}))) == ["clickhouse_log_storm"]
  end

  describe "parsing the status line the cron writes" do
    test "the shape /root/ch_log_check.sh writes, with its trailing newline" do
      now = ~U[2026-11-05 03:35:01Z]
      s = Metrics.parse_ch_log_status("2026-11-05T03:30:01Z storm_5m=0 lines_5m=12 journald_cpu_pct=1\n", now)
      assert s == %{at: ~U[2026-11-05 03:30:01Z], age_s: 300, storm_5m: 0, lines_5m: 12, journald_cpu_pct: 1}
    end

    test "the last line wins if the file ever holds more than one" do
      text = "2026-11-05T03:25:01Z storm_5m=900 lines_5m=9000 journald_cpu_pct=49\n2026-11-05T03:30:01Z storm_5m=0 lines_5m=3 journald_cpu_pct=0\n"
      assert %{storm_5m: 0, lines_5m: 3} = Metrics.parse_ch_log_status(text, ~U[2026-11-05 03:31:00Z])
    end

    test "a clock skew where the line is in the future reads as age zero, not negative" do
      s = Metrics.parse_ch_log_status("2026-11-05T03:30:01Z storm_5m=0 lines_5m=0 journald_cpu_pct=0", ~U[2026-11-05 03:20:00Z])
      assert s.age_s == 0
    end

    test "hostile or broken text is nil, never a half-parsed map" do
      now = ~U[2026-11-05 03:35:01Z]

      for text <- [
            "",
            "\n\n",
            "hello",
            "2026-11-05T03:30:01Z",
            "2026-11-05T03:30:01Z storm_5m=0 lines_5m=12",
            "2026-11-05T03:30:01Z storm_5m=-1 lines_5m=12 journald_cpu_pct=1",
            "2026-11-05T03:30:01Z storm_5m=0 lines_5m=12 journald_cpu_pct=49.0",
            "2026-11-05T03:30:01Z storm_5m=zero lines_5m=12 journald_cpu_pct=1",
            "2026-11-05T03:30:01Z storm_5m= lines_5m=12 journald_cpu_pct=1",
            "not-a-date storm_5m=0 lines_5m=12 journald_cpu_pct=1",
            "2026-11-05T03:30:01Z storm_5m=0\x00 lines_5m=12 journald_cpu_pct=1",
            String.duplicate("x", 100_000)
          ] do
        assert Metrics.parse_ch_log_status(text, now) == nil, inspect(text, limit: 60)
      end

      assert Metrics.parse_ch_log_status(nil, now) == nil
      assert Metrics.parse_ch_log_status(%{storm_5m: 0}, now) == nil
    end

    test "very large counts parse (a storm of a day is millions of lines)" do
      s = Metrics.parse_ch_log_status("2026-11-05T03:30:01Z storm_5m=4080000 lines_5m=40800000 journald_cpu_pct=100", ~U[2026-11-05 03:31:00Z])
      assert s.storm_5m == 4_080_000
    end
  end

  test "on a box without the status file the metric is nil, so a laptop raises nothing" do
    # The path is the master's; this test runs where it does not exist.
    if File.exists?("/var/log/listsignal_ch_log_status"),
      do: assert(is_map(Metrics.clickhouse_log_status()) or is_nil(Metrics.clickhouse_log_status())),
      else: assert(Metrics.clickhouse_log_status() == nil)
  end
end
