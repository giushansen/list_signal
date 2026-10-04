defmodule LS.Ops.BackupLogSizeTest do
  use ExUnit.Case, async: true

  alias LS.Ops.BackupLog

  @moduledoc """
  2026-10-04: the weekly ClickHouse tier still named domains_history, which
  the 10-01 data model v2 migration had renamed to enrich_log. It matched no
  table, tarred an empty directory and logged "clickhouse ok (12K)" in one
  second. This module read the run as successful, so neither the run alert
  nor the stale-age alert fired, and an hour later the retry shipped that
  12 KB archive over the 46.8G copy of 2026-09-27, the only backup of crawl
  history that existed. A success line has to report a real archive.
  """

  defp line(size), do: "2026-10-04 03:15:01 [ch] clickhouse ok (#{size})"

  test "a gigabyte archive is plausible, anything smaller is not" do
    assert BackupLog.plausible_ch_size?(line("42G"))
    assert BackupLog.plausible_ch_size?(line("4.4G"))
    assert BackupLog.plausible_ch_size?(line("1T"))
    refute BackupLog.plausible_ch_size?(line("12K"))
    refute BackupLog.plausible_ch_size?(line("900M"))
    refute BackupLog.plausible_ch_size?(line("10240B"))
    refute BackupLog.plausible_ch_size?(line("0.5G"))
  end

  test "both shapes the script writes are read, and an unreadable one is refused" do
    # The local-tar shape, used until 2026-10-04.
    assert BackupLog.plausible_ch_size?("2026-09-27 03:33:00 [ch] clickhouse ok (42G)")
    # The streamed shape, from 2026-10-04 on.
    assert BackupLog.plausible_ch_size?(
             "2026-10-04 04:30:00 [ch] clickhouse ok: chw_20261004_040518.tar streamed offsite (46G, 1 tables, 2 entries verified)"
           )

    refute BackupLog.plausible_ch_size?("2026-10-04 04:30:00 [ch] clickhouse ok")
    refute BackupLog.plausible_ch_size?("")
    refute BackupLog.plausible_ch_size?(nil)
  end

  test "the run that dumped nothing reads as a failed run, not a successful one" do
    log = """
    2026-10-04 03:15:01 [ch] === backup start (disk 71%) ===
    2026-10-04 03:15:01 [ch] clickhouse ok (12K)
    2026-10-04 03:15:02 [ch] === backup done (disk 71%, 1 CH archives, 60 sqlite) ===
    """

    assert %{result: :error, started_at: "2026-10-04 03:15:01"} = BackupLog.last_ch_run(log)
  end

  test "a real run still reads as successful, in both shapes" do
    old = """
    2026-09-27 03:15:01 [ch] === backup start (disk 74%) ===
    2026-09-27 03:33:00 [ch] clickhouse ok (42G)
    """

    new = """
    2026-10-04 04:05:18 [ch] === backup start (disk 71%) ===
    2026-10-04 04:30:00 [ch] clickhouse ok: chw_20261004_040518.tar streamed offsite (46G, 1 tables, 2 entries verified)
    """

    assert %{result: :ok} = BackupLog.last_ch_run(old)
    assert %{result: :ok} = BackupLog.last_ch_run(new)
  end

  test "the age of the last good dump ignores a success line with no real archive" do
    log = """
    2026-09-27 03:15:01 [ch] === backup start (disk 74%) ===
    2026-09-27 03:33:00 [ch] clickhouse ok (42G)
    2026-10-04 03:15:01 [ch] === backup start (disk 71%) ===
    2026-10-04 03:15:01 [ch] clickhouse ok (12K)
    """

    assert BackupLog.last_ch_ok_at(log) == "2026-09-27 03:33:00"
  end
end
