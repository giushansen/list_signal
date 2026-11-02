defmodule LS.CacheCtlPersistTest do
  @moduledoc """
  2026-11-02: LS.CacheSnapshot kept a 1M sample of the up to 5M CT dedup
  rows, so a restart after four days forgot ~4M domains; their certificate
  renewals came back as new and first fetches fell from 4,413 to 528 an
  hour. The table is now written whole and rows past the TTL dropped on
  restore. LS.Cache is not running under `mix test`, so each test owns the
  table it creates, under its own name, and it dies with the test.
  """
  use ExUnit.Case, async: false

  alias LS.Cache

  @table @table

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    path = Path.join(System.tmp_dir!(), "ctl_persist_#{System.unique_integer([:positive])}.ets")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  test "rows survive a save and restore; expired rows do not", %{path: path} do
    assert Cache.restore_ctl(path, @table) == 0
    now = System.system_time(:second)
    :ets.insert(@table, {"fresh.com", {3, 1, now - 60, now - 60}})
    :ets.insert(@table, {"old.com", {1, 0, now - 20 * 86_400, now - 20 * 86_400}})

    assert {:ok, 2} = Cache.save_ctl(path, @table)
    :ets.delete(@table)
    assert Cache.restore_ctl(path, @table) == 1
    assert [{"fresh.com", {3, 1, _, _}}] = :ets.lookup(@table, "fresh.com")
    assert :ets.lookup(@table, "old.com") == []
  end

  test "an empty table writes nothing, so a worker never produces a file", %{path: path} do
    Cache.restore_ctl(path, @table)
    assert Cache.save_ctl(path, @table) == {:ok, 0}
    refute File.exists?(path)
  end

  test "a corrupt file starts an empty table instead of crashing boot", %{path: path} do
    File.write!(path, "garbage")
    assert Cache.restore_ctl(path, @table) == 0
    assert :ets.info(@table, :size) == 0
  end

  test "no state dir, no path" do
    assert Application.get_env(:ls, :state_dir) == nil
    assert Cache.ctl_path() == nil
    assert Cache.save_ctl(nil) == {:ok, 0}
  end
end
