defmodule LS.Ops.NodeResourcesTest do
  use ExUnit.Case, async: true

  alias LS.Ops.NodeResources

  @moduledoc """
  Pure parsing behind the 2026-08-30 danger-signal redesign: PSI stall time
  and systemd restart reason, both read from real kernel/systemd text output.
  """

  describe "parse_restart_info/2 — real systemctl show output" do
    test "a normal deploy or clean stop" do
      out = "Result=success\nNRestarts=0\n"
      assert NodeResources.parse_restart_info(out, :result) == "success"
      assert NodeResources.parse_restart_info(out, :count) == 0
    end

    test "an OOM kill, mid-fleet, several restarts in" do
      out = "Result=oom-kill\nNRestarts=3\n"
      assert NodeResources.parse_restart_info(out, :result) == "oom-kill"
      assert NodeResources.parse_restart_info(out, :count) == 3
    end

    test "other real systemd Result values are read, not just the two seen so far" do
      for r <- ~w(signal exit-code timeout watchdog core-dump) do
        out = "Result=#{r}\nNRestarts=1\n"
        assert NodeResources.parse_restart_info(out, :result) == r
      end
    end

    test "hostile or truncated output returns nil rather than raising" do
      for bad <- ["", "garbage", "Result=\n", "NRestarts=\n", "Result=success", String.duplicate("x", 5_000)] do
        assert NodeResources.parse_restart_info(bad, :result) == nil or is_binary(NodeResources.parse_restart_info(bad, :result))
        assert NodeResources.parse_restart_info(bad, :count) == nil or is_integer(NodeResources.parse_restart_info(bad, :count))
      end
    end
  end

  describe "local/0 never raises, whatever the platform" do
    test "returns every documented key even on a non-Linux dev machine" do
      r = NodeResources.local()

      for key <- [
            :cores,
            :load1,
            :mem_total_mb,
            :mem_avail_mb,
            :mem_pressure_full_avg10,
            :mem_pressure_full_avg60,
            :disk_total_gb,
            :restart_result,
            :restart_count,
            :beam_mb
          ] do
        assert Map.has_key?(r, key), "local/0 dropped #{key}"
      end

      assert is_integer(r.beam_mb)
    end
  end

  describe "local/0 shells out once for restart info, not twice" do
    test "restart_result and restart_count share a single systemctl call" do
      # 2026-08-31: local/0 used to call restart_info(:result) and
      # restart_info(:count) separately, each forking a fresh `systemctl
      # show` process — even though one call already returns both fields.
      # Forking is the slow path on a node under real memory pressure
      # (swap-in page faults on the new process's own pages), so the extra
      # fork made this erpc-polled collector itself more likely to blow the
      # master's 3s timeout right when a node was thrashing, turning one
      # real memory-pressure event into a second "node unmonitored" alert.
      src = File.read!("lib/ls/ops/node_resources.ex")

      local_body =
        src |> String.split("def local do") |> Enum.at(1) |> String.split("def restart_info") |> List.first()

      assert Regex.scan(~r/restart_info\(/, local_body) |> length() == 1,
             "local/0 must fetch restart result and count from a single restart_info() call"

      restart_info_body =
        src |> String.split("def restart_info do") |> Enum.at(1) |> String.split("def parse_restart_info") |> List.first()

      assert Regex.scan(~r/System\.cmd\(/, restart_info_body) |> length() == 1,
             "restart_info/0 must shell out to systemctl exactly once"
    end
  end
end
