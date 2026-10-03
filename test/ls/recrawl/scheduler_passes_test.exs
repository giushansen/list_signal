defmodule LS.Recrawl.SchedulerPassesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-03 evening: the liveness check found 73% of each 12,500 due
  block dead, so a tick enqueued about 3,150 live names, a quarter of the
  refresh budget. A tick now reads further down the due list in the same
  order, block by block, until it has the live names it was sized for.
  """

  test "the due query takes an offset and orders deterministically so blocks do not overlap" do
    sql = LS.Clickhouse.stale_domains_sql(1000, 12_500)
    assert sql =~ "ORDER BY tier ASC, http_last_checked_at ASC, domain"
    assert sql =~ "LIMIT 1000 OFFSET 12500"
    assert LS.Clickhouse.stale_domains_sql(1000) =~ "LIMIT 1000 OFFSET 0"
  end

  test "a tick never enqueues past its quota, whatever the later blocks hold" do
    plan = LS.Recrawl.Scheduler.plan()
    assert LS.Recrawl.Scheduler.quota_left(0) == plan.batch_size
    assert LS.Recrawl.Scheduler.quota_left(7_051) == plan.batch_size - 7_051
    assert LS.Recrawl.Scheduler.quota_left(plan.batch_size) == 0
    assert LS.Recrawl.Scheduler.quota_left(plan.batch_size + 500) == 0
  end

  test "a tick reads at most a few blocks, so a dead-dominated list cannot run the tick past its interval" do
    plan = LS.Recrawl.Scheduler.plan()
    assert plan.max_passes in 2..4
    assert plan.max_passes * plan.batch_size <= 50_000
  end
end
