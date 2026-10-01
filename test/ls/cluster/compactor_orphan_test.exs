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

  test "compact_sql carries a server ceiling under the 600s incremental client timeout" do
    src = File.read!("lib/ls/clickhouse/compact.ex")

    assert src =~ ~r/max_s \\\\ 1190/,
           "the incremental default must sit just under compact_businesses' 1200s client timeout"
    assert src =~ "query_raw(scratch_sql(scratch, since_unix, until_unix), 1_200_000, background: true)"

    assert src =~ "max_execution_time = \#{max_s}",
           "the ceiling must be in the SQL SETTINGS so the server enforces it"
  end

  test "the full rebuild keeps its legitimate 30-minute budget" do
    # An 8-minute repair query under a 290s ceiling would make rebuild_all
    # permanently impossible — the ceiling is per-caller, not global.
    src = File.read!("lib/ls/clickhouse/compact.ex")
    assert src =~ "compact_sql(0, nil, 1790)"
  end

  test "the touched-domain set is computed once and every scope reads it (2026-09-06)" do
    # Six inlined copies of a UNION whose first leg full-scans the current
    # domains_history partition took every incremental pass past 590s.
    src = File.read!("lib/ls/clickhouse/compact.ex")
    [c | _] = String.split(src, "def fold_select_sql(since_unix") |> Enum.drop(1)
    [c | _] = String.split(c, "def history_rows_sql")
    assert c =~ "(SELECT groupUniqArray(domain) FROM (\#{domain_set})) AS _touched"
    # 2026-09-07: the history side no longer reads by touched set at all
    # (that read was the whole table, see history_rows_sql/2); the compiled
    # rows, the depth side and the five join sides do (contacts joined
    # since data model v2).
    sql = LS.Clickhouse.compact_sql_for_test(1_700_000_000, 1_700_000_300)
    assert length(String.split(sql, "IN (SELECT arrayJoin(_touched))")) == 8, "businesses, depth, pricing, news, verified, sightings, contacts"
    assert c =~ "FROM (\#{history_rows_sql(since_unix, until_unix)})"
    refute c =~ "IN (\#{domain_set})", "no scope may inline the set again"
    assert c =~ "\#{touched}SELECT"
  end

  test "the change detection and the stable check die with their 120s client too" do
    assert LS.Schema.Changes.detect_sql("tmp_x") =~ "max_execution_time = 115"
    assert LS.Clickhouse.stable_domains_sql(1, 2) =~ "max_execution_time = 115"
    src = File.read!("lib/ls/clickhouse/compact.ex")
    assert src =~ "query_raw(Changes.detect_sql(scratch), 120_000, background: true)"
  end
end
