defmodule LS.Cluster.InserterShutdownTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A deploy's stop phase must finish inside the unit's 20s TimeoutStopSec
  (2026-09-07). With ClickHouse starved the inserter's shutdown flush
  waited out its 30s receive plus 15s pool timeouts and systemd SIGKILLed
  the app mid-flush. Losing a batch cleanly beats being killed.
  """

  test "the shutdown flush is capped well under the unit's stop timeout" do
    assert LS.Cluster.Inserter.shutdown_flush_ms() <= 10_000
    src = File.read!("lib/ls/cluster/inserter.ex")
    assert src =~ "Task.yield(task, @shutdown_flush_ms) || Task.shutdown(task, :brutal_kill)"
  end
end
