defmodule LS.StateTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Durable node state moved out of /tmp on 2026-09-09: systemd-tmpfiles prunes
  /tmp after 10 days, and a shared /tmp blocked PrivateTmp in the unit.
  """

  setup do
    saved = Application.get_env(:ls, :state_dir)
    on_exit(fn -> if saved, do: Application.put_env(:ls, :state_dir, saved), else: Application.delete_env(:ls, :state_dir) end)
    :ok
  end

  test "the configured directory is created and used" do
    dir = Path.join(System.tmp_dir!(), "ls_state_#{System.unique_integer([:positive])}")
    Application.put_env(:ls, :state_dir, dir)
    assert LS.State.dir() == dir
    assert File.dir?(dir)
    File.rm_rf!(dir)
  end

  test "an unwritable directory falls back to the temp dir instead of breaking boot" do
    Application.put_env(:ls, :state_dir, "/proc/ls_cannot_write_here")
    assert LS.State.dir() == System.tmp_dir!()
  end

  test "nothing configured means the temp dir, so a laptop needs no setup" do
    Application.delete_env(:ls, :state_dir)
    assert LS.State.dir() == System.tmp_dir!()
  end

  test "the cache snapshot lives under the state dir, and the old /tmp file is still read once" do
    dir = Path.join(System.tmp_dir!(), "ls_state_#{System.unique_integer([:positive])}")
    Application.put_env(:ls, :state_dir, dir)
    Application.delete_env(:ls, :cache_snapshot_path)
    assert LS.CacheSnapshot.path() == Path.join(dir, "cache_snapshot.bin")
    assert LS.CacheSnapshot.legacy_path() == Path.join(System.tmp_dir!(), "ls_cache_snapshot.bin")
    File.rm_rf!(dir)
  end
end
