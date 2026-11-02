defmodule LS.Cluster.WorkQueuePersistTest do
  @moduledoc """
  2026-11-02: the master deploy at 01:48 UTC started the queue at 60 items
  against 153.5K. The dropped domains were already marked in the 7-8 day
  bloom, so nothing re-queued them for a week. The queue now goes to disk
  on a graceful stop and every 15 minutes, and comes back in order. The
  live server keeps its own table; each test owns one under another name.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue

  @table @table

  setup do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table)
    path = Path.join(System.tmp_dir!(), "wq_persist_#{System.unique_integer([:positive])}.ets")
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  defp item(i), do: %{ctl_domain: "persist-#{i}.com", ctl_tld: "com", source: if(rem(i, 7) == 0, do: :recrawl, else: :ctl)}

  test "saved items come back in their order under fresh keys", %{path: path} do
    assert WorkQueue.restore_queue(path, @table) == 0
    now = System.system_time(:millisecond)
    for i <- 1..50, do: :ets.insert(@table, {WorkQueue.tail_key(item(i)), item(i), now})
    before = :ets.tab2list(@table)

    assert {:ok, 50} = WorkQueue.save_queue(path, @table)
    :ets.delete(@table)
    assert WorkQueue.restore_queue(path, @table) == 50
    after_ = :ets.tab2list(@table)

    assert Enum.map(after_, fn {_k, d, t} -> {d, t} end) == Enum.map(before, fn {_k, d, t} -> {d, t} end)
    assert Enum.map(after_, &elem(&1, 0)) != Enum.map(before, &elem(&1, 0))

    # A new item sorts after every restored one and overwrites none.
    :ets.insert(@table, {WorkQueue.tail_key(item(99)), item(99), now})
    assert :ets.info(@table, :size) == 51
    assert {_, %{ctl_domain: "persist-99.com"}, _} = :ets.lookup(@table, :ets.last(@table)) |> hd()
  end

  test "no file means an empty queue, and a corrupt file is ignored", %{path: path} do
    assert WorkQueue.restore_queue(path, @table) == 0
    assert :ets.info(@table, :size) == 0
    :ets.delete(@table)

    File.write!(path, "not an ets file")
    assert WorkQueue.restore_queue(path, @table) == 0
    assert :ets.info(@table, :size) == 0
  end

  test "without a configured state dir nothing is written (a laptop test run must not seed the next)" do
    assert Application.get_env(:ls, :state_dir) == nil
    assert WorkQueue.queue_path() == nil
    assert WorkQueue.save_queue(nil) == {:ok, 0}
  end
end
