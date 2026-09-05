defmodule LS.Cluster.CompactorOrphanTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Every heavy compaction/signals query must carry a SERVER-side
  max_execution_time sized just under its client timeout.

  2026-09-05: the compactor's client gave up on a slow pass at its receive
  timeout, but the INSERT kept running on ClickHouse — 32 minutes, 2 GiB —
  while retries stacked more copies on top, until the server hit
  MEMORY_LIMIT_EXCEEDED and the `businesses` table stopped being compiled.
  "New businesses" halved for two hours; the DataCheck quantity alert is
  what surfaced it. A query the client has abandoned must die with the
  client, not outlive it.
  """

  test "compact_sql carries a server ceiling under the 300s incremental client timeout" do
    src = File.read!("lib/ls/clickhouse.ex")

    assert src =~ ~r/max_s \\\\ 290/,
           "the incremental default must sit just under compact_businesses' 300s client timeout"

    assert src =~ "max_execution_time = \#{max_s}",
           "the ceiling must be in the SQL SETTINGS so the server enforces it"
  end

  test "the full rebuild keeps its legitimate 30-minute budget" do
    # An 8-minute repair query under a 290s ceiling would make rebuild_all
    # permanently impossible — the ceiling is per-caller, not global.
    src = File.read!("lib/ls/clickhouse.ex")
    assert src =~ "compact_sql(0, nil, 1790)"
  end

  test "the signals queries die with their 120s client too" do
    src = File.read!("lib/ls/clickhouse.ex")
    [signals | _] = String.split(src, "def record_signals") |> Enum.drop(1)
    [signals | _] = String.split(signals, "def backfill_signals_shard")

    assert length(String.split(signals, "max_execution_time = 115")) == 3,
           "both the tech and hiring signal INSERTs must carry the server ceiling"
  end
end
