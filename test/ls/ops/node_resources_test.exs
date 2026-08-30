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
end
