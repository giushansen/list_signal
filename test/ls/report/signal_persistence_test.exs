defmodule LS.Report.SignalPersistenceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The free precision metric for change events (2026-09-06): of the events
  detected 8 weeks ago, the share still true today. It must reach the
  weekly email, and a kind under 80% must be visibly flagged, or a
  detector that starts flapping is noticed only when a customer complains.
  """

  test "the weekly report renders the persistence chapter with a flag under 80%" do
    src = File.read!("lib/ls/report/weekly.ex")
    assert src =~ "Metrics.signal_persistence()"
    assert src =~ "chapter(\"Signal quality\", persistence_table(persist))"
    assert src =~ "r.holds_pct < 80"
  end

  test "the metric compares events 8 to 9 weeks old against the current businesses row, per kind" do
    src = File.read!("lib/ls/metrics.ex")
    [q | _] = String.split(src, "def signal_persistence") |> Enum.drop(1)
    [q | _] = String.split(q, "\n  end\n")
    assert q =~ "INTERVAL 63 DAY" and q =~ "INTERVAL 56 DAY"
    for k <- ~w(tech_added tech_removed app_added app_removed started_hiring stopped_hiring), do: assert(q =~ k)
    assert q =~ "businesses FINAL"
    assert q =~ "max_execution_time = 240"
  end
end
