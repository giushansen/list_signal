defmodule LS.Cluster.WorkQueueEdgeCapEnvTest do
  # async: false on purpose: the cap is read from the application env, and
  # work_queue_edge_cap_test pins the compiled default while running async.
  # Sync tests run after every async test has finished, so this one can
  # change the env without the other one seeing it.
  use ExUnit.Case, async: false

  @moduledoc """
  2026-11-05: with the lane finishing every store it took (1b13634), the
  compiled cap of eight shared-edge stores per batch (3c5b03a) was what
  held Shopify at 265 to 333 stores per 15 minutes fleet-wide, half the
  target: eight stores x three batches x about 1.5 batches per 15 minutes
  x seven duals. The right cap follows how fast the lane finishes, so the
  master's LS_EDGE_PER_BATCH (config :edge_per_batch) moves it without a
  release. The compiled default stays eight, and junk falls back to it.
  """

  alias LS.Cluster.WorkQueue

  setup do
    case GenServer.whereis(WorkQueue) do
      nil ->
        {:ok, pid} = WorkQueue.start_link()
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      _ ->
        :ok
    end

    prev = Application.get_env(:ls, :edge_per_batch)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ls, :edge_per_batch)
        v -> Application.put_env(:ls, :edge_per_batch, v)
      end
    end)

    Application.delete_env(:ls, :edge_per_batch)
    drain()
    :ok
  end

  defp drain do
    case GenServer.call(WorkQueue, {:dequeue, 10_000}) do
      {:ok, bid, _} ->
        GenServer.cast(WorkQueue, {:complete, bid, []})
        _ = WorkQueue.stats()
        drain()

      {:empty, []} ->
        :ok
    end
  end

  defp store(i), do: %{ctl_domain: "s#{i}-#{System.unique_integer([:positive])}.test", source: :recrawl, tier: "a", prev_simhash: 0, edge: true}
  defp plain(i), do: %{ctl_domain: "p#{i}-#{System.unique_integer([:positive])}.test", source: :recrawl, tier: "a", prev_simhash: 0}

  defp dequeue(n) do
    {:ok, bid, items} = GenServer.call(WorkQueue, {:dequeue, n})
    GenServer.cast(WorkQueue, {:complete, bid, []})
    _ = WorkQueue.stats()
    items
  end

  test "nothing configured means the compiled default of eight" do
    assert WorkQueue.edge_per_batch() == 8
    assert WorkQueue.cap_or_default(nil) == 8
  end

  test "a cap of sixteen lets a batch hold sixteen stores and leaves the rest in place" do
    Application.put_env(:ls, :edge_per_batch, 16)
    assert WorkQueue.edge_per_batch() == 16

    for i <- 1..20, do: :ok = WorkQueue.enqueue(store(i), force: true)
    for i <- 1..10, do: :ok = WorkQueue.enqueue(plain(i), force: true)

    items = dequeue(30)
    assert Enum.count(items, &WorkQueue.edge?/1) == 16
    assert Enum.count(items, &(not WorkQueue.edge?(&1))) == 10
    assert WorkQueue.stats().queue_depth == 4

    # The four that waited are the next batch's, still capped.
    again = dequeue(30)
    assert length(again) == 4
    assert Enum.all?(again, &WorkQueue.edge?/1)
  end

  test "a cap of one still holds, so the lever works in both directions" do
    Application.put_env(:ls, :edge_per_batch, 1)
    for i <- 1..5, do: :ok = WorkQueue.enqueue(store(i), force: true)
    assert length(dequeue(5)) == 1
    assert WorkQueue.stats().queue_depth == 4
  end

  test "junk in the config falls back to eight rather than opening or closing the cap" do
    for junk <- [0, -3, "16", "", 2.5, :sixteen, [16], %{cap: 16}] do
      assert WorkQueue.cap_or_default(junk) == 8, inspect(junk)
      Application.put_env(:ls, :edge_per_batch, junk)
      assert WorkQueue.edge_per_batch() == 8, inspect(junk)
    end

    Application.put_env(:ls, :edge_per_batch, 0)
    for i <- 1..12, do: :ok = WorkQueue.enqueue(store(i), force: true)
    assert length(dequeue(12)) == 8
  end
end
