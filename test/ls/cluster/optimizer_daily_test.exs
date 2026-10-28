defmodule LS.Cluster.OptimizerDailyTest do
  @moduledoc """
  2026-10-28: the owner's dashboard took 11 s at 02:26 UTC, inside the hourly
  `OPTIMIZE TABLE businesses FINAL` pass (27 passes a day, 180 s each, a
  full rewrite of 11.7 GB on the 4-core box that serves customers). The
  pass now runs once a day at 11:30 UTC, the measured minimum of web
  traffic. These pin the schedule.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.Optimizer

  test "the next pass is at 11:30 UTC the same day when that is still ahead" do
    now = ~U[2026-10-28 02:26:00Z]
    assert Optimizer.delay_to_quiet_hour_ms(now) == :timer.hours(9) + :timer.minutes(4)
  end

  test "after 11:30 UTC the next pass is tomorrow, never within the hour" do
    now = ~U[2026-10-28 11:31:00Z]
    delay = Optimizer.delay_to_quiet_hour_ms(now)
    assert delay == :timer.hours(24) - :timer.minutes(1)
    assert delay > :timer.hours(1)
  end

  test "a pass is never scheduled under a minute away, so a restart at 11:29:30 does not optimize at boot" do
    assert Optimizer.delay_to_quiet_hour_ms(~U[2026-10-28 11:29:30Z]) > :timer.hours(23)
    assert Optimizer.delay_to_quiet_hour_ms(~U[2026-10-28 11:29:00Z]) == :timer.minutes(1)
  end

  test "the pass lands in the quiet window, not in the owner's morning (00:00 to 03:00 UTC)" do
    for h <- 0..23 do
      now = DateTime.new!(~D[2026-10-28], Time.new!(h, 0, 0), "Etc/UTC")
      at = DateTime.add(now, Optimizer.delay_to_quiet_hour_ms(now), :millisecond)
      assert at.hour == 11 and at.minute == 30
    end
  end
end
