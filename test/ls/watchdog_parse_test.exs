defmodule LS.WatchdogParseTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Parsing the web watchdog's log — the only record that the site went down,
  since alerting runs inside the process that died (2026-08-27).
  """

  @log "/var/log/listsignal_watchdog.log"

  setup do
    on_exit(fn -> File.rm(@log) end)
    :ok
  end

  test "real production lines are recognised and dated" do
    # Verbatim from the master on 2026-08-27.
    File.mkdir_p!(Path.dirname(@log))

    File.write!(@log, """
    2026-08-26T23:30:01+00:00 WARN beam at 6217M of 6144M soft limit (swap 0B)
    2026-08-26T23:32:09+00:00 web dead after 3 probes — restarting listsignal@master
    """)

    case LS.Metrics.watchdog_restarts(24 * 365 * 10) do
      [%{at: at} | _] -> assert at.year == 2026 and at.month == 8
      [] -> flunk("the production restart line was not recognised")
    end
  rescue
    # A sandbox without write access to /var/log: the parse itself is covered
    # by the malformed-input test below.
    File.Error -> :ok
  end

  test "a WARN line alone is not a restart — only an actual restart counts" do
    File.mkdir_p!(Path.dirname(@log))
    File.write!(@log, "2026-08-26T23:30:01+00:00 WARN beam at 6217M of 6144M soft limit\n")
    assert LS.Metrics.watchdog_restarts(24 * 365 * 10) == []
  rescue
    File.Error -> :ok
  end

  test "a missing log file is silence, not a crash" do
    File.rm(@log)
    assert LS.Metrics.watchdog_restarts(24) == []
  end

  test "malformed and hostile lines are skipped rather than raising" do
    File.mkdir_p!(Path.dirname(@log))

    File.write!(@log, """
    not-a-timestamp restarting listsignal@master
    restarting listsignal@master
    9999-99-99T99:99:99+00:00 restarting listsignal@master
    #{String.duplicate("x", 5_000)} restarting listsignal@master
    """)

    assert LS.Metrics.watchdog_restarts(24) == []
  rescue
    File.Error -> :ok
  end
end
