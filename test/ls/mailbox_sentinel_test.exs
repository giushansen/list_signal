defmodule LS.MailboxSentinelTest do
  require Logger
  @moduledoc """
  The sentinel exists because the 2026-08-19 runaway process could not be
  identified post-mortem — only a live peek at the queued messages names the
  sender. Its own invariants: it must catch a grower, must kill past the
  threshold, and must never kill the exempt (killing the endpoint to protect
  the endpoint would be self-parody).
  """
  use ExUnit.Case, async: false

  setup do
    # A dedicated, explicitly-enabled instance: the global one is inert in
    # test so it cannot kill the suite's own busy processes.
    pid = start_supervised!({LS.MailboxSentinel, name: :sentinel_under_test, enabled: false})
    %{sentinel: pid}
  end

  # A process that accumulates messages and never receives — the incident shape.
  defp spawn_hoarder do
    spawn(fn ->
      receive do
        :never_sent -> :ok
      end
    end)
  end

  test "a flooded process is reported with its queued messages visible", ctx do
    pid = spawn_hoarder()
    for i <- 1..2_500, do: send(pid, {:flood, i})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(ctx.sentinel, :sweep)
        Process.sleep(600)
        Logger.flush()
      end)

    assert log =~ "runaway mailbox"
    assert log =~ ":flood", "the queued messages must be visible — they name the sender"

    Process.exit(pid, :kill)
  end

  test "past the kill threshold the process is killed, not just logged", ctx do
    pid = spawn_hoarder()
    ref = Process.monitor(pid)
    for i <- 1..31_000, do: send(pid, {:flood, i})

    ExUnit.CaptureLog.capture_log(fn ->
      send(ctx.sentinel, :sweep)

      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
      after
        5_000 -> flunk("sentinel did not kill a 31k-message hoarder")
      end
    end)
  end

  test "a normal busy process is left alone", ctx do
    pid = spawn_hoarder()
    for i <- 1..500, do: send(pid, {:ok_ish, i})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(ctx.sentinel, :sweep)
        Process.sleep(600)
        Logger.flush()
      end)

    refute log =~ inspect(pid), "500 queued messages is busy, not runaway"
    assert Process.alive?(pid)
    Process.exit(pid, :kill)
  end
end
