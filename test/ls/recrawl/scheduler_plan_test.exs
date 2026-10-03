defmodule LS.Recrawl.SchedulerPlanTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-03: the first tiered scheduler enqueued 150K known businesses
  every six hours in one block. A known business passes the crawl gate 93%
  of the time against 37% for a new name, so the batches drawn from that
  block carried about 930 HTTP candidates instead of 370, took 25 minutes
  against a ceiling shared by two batches, and on chi2 two of them died at
  their deadline with every result discarded. The same 600K a day is now
  spread over 48 runs so refreshes mix with discovery.
  """

  test "the plan spreads the daily refresh ceiling over small, frequent runs" do
    plan = LS.Recrawl.Scheduler.plan()
    assert plan.per_day == 600_000
    assert plan.runs_per_day == 48
    assert plan.batch_size <= 15_000, "a run must be small enough to mix with discovery"
    assert plan.interval_ms <= 30 * 60_000
    assert plan.queue_headroom <= 150_000, "a refresh never buries discovery"
  end
end
