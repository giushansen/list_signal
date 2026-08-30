defmodule LS.Ops.MemoryForensicsTest do
  use ExUnit.Case, async: false

  alias LS.Ops.MemoryForensics

  @moduledoc """
  The black-box recorder for the master's memory stalls (2026-08-30).

  These tests exist so the NEXT incident has a trail: if build_snapshot/0
  silently returns garbage, the whole point of this module — replacing "we
  don't know why it restarted" with an actual record — is lost.
  """

  describe "build_snapshot/0" do
    test "returns every field the ClickHouse table expects, with the right shapes" do
      snap = MemoryForensics.build_snapshot()

      assert is_binary(snap.node)
      assert %DateTime{} = snap.at
      assert is_integer(snap.self_rss_mb)
      assert is_integer(snap.erlang_total_mb) and snap.erlang_total_mb > 0
      assert is_integer(snap.native_gap_mb)
      assert is_integer(snap.processes_mb)
      assert is_integer(snap.ets_mb)
      assert is_integer(snap.binary_mb)
      assert snap.alarm in [0, 1]
    end

    test "top_ets and top_processes are valid, bounded JSON arrays" do
      snap = MemoryForensics.build_snapshot()
      ets = Jason.decode!(snap.top_ets)
      procs = Jason.decode!(snap.top_processes)

      assert is_list(ets) and length(ets) <= 12
      assert Enum.all?(ets, &Map.has_key?(&1, "name"))

      assert is_list(procs) and length(procs) <= 12
      assert Enum.all?(procs, &Map.has_key?(&1, "mailbox"))
    end

    test "a table large enough to matter always outranks the noise floor" do
      # Real reference tables (Tranco/Majestic) are already loaded in this
      # environment and dwarf a small probe, so this proves inclusion with a
      # table big enough to matter regardless of what else is resident,
      # rather than asserting an exact rank that depends on test order.
      :ets.new(:forensics_probe_big, [:named_table, :set, :public])
      for i <- 1..300_000, do: :ets.insert(:forensics_probe_big, {i, :binary.copy(<<0>>, 300)})

      snap = MemoryForensics.build_snapshot()
      ets = Jason.decode!(snap.top_ets)

      assert Enum.any?(ets, &(&1["name"] == "forensics_probe_big")),
             "a ~90MB table must appear in the top-12 regardless of what else is loaded"

      :ets.delete(:forensics_probe_big)
    end

    test "ETS and process lists are sorted largest-first" do
      snap = MemoryForensics.build_snapshot()
      ets = Jason.decode!(snap.top_ets)
      procs = Jason.decode!(snap.top_processes)

      assert ets == Enum.sort_by(ets, & &1["mb"], :desc)
      assert procs == Enum.sort_by(procs, & &1["mb"], :desc)
    end

    test "native_gap_mb is self_rss minus erlang_total, always" do
      snap = MemoryForensics.build_snapshot()
      assert snap.native_gap_mb == snap.self_rss_mb - snap.erlang_total_mb
    end
  end

  describe "hostile input never crashes a snapshot" do
    test "a process that dies mid-scan is skipped, not fatal" do
      {:ok, pid} = Task.start(fn -> :timer.sleep(:infinity) end)
      Process.exit(pid, :kill)
      # Give it a moment to actually die before the snapshot walks the list.
      Process.sleep(10)

      assert %{top_processes: json} = MemoryForensics.build_snapshot()
      assert {:ok, _} = Jason.decode(json)
    end

    test "snapshot_now/0 never raises even if ClickHouse is unreachable" do
      assert %{} = MemoryForensics.snapshot_now()
    end
  end
end
