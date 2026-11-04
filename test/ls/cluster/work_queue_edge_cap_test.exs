defmodule LS.Cluster.WorkQueueEdgeCapTest do
  @moduledoc """
  2026-11-04, second hour of the shared-edge lane: the priority queue held
  9,522 Shopify stores among 18,646 names, in runs of up to 413, because
  the tier A slice enqueues its Shopify share back to back and a cut
  batch returns its stores to the tail together. A batch that landed on
  a run fetched 13 of 82 stores in its whole 420 s stage on ny1 (17:14
  and 17:21 UTC) and returned 69 as the next run; the duals did 17 to 22
  rows a minute instead of 35. A batch now holds at most
  WorkQueue.edge_per_batch/0 names tagged `edge: true`; the rest stay in
  place, in order, for the batches after it.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue
  alias LS.Cluster.WorkerAgent

  setup do
    case GenServer.whereis(WorkQueue) do
      nil ->
        {:ok, pid} = WorkQueue.start_link()
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      _ ->
        :ok
    end

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
  defp new(i), do: %{ctl_domain: "n#{i}-#{System.unique_integer([:positive])}.test", source: :ctl}

  defp names({:ok, _bid, items}), do: Enum.map(items, & &1.ctl_domain)
  defp prefix(name), do: String.first(name)

  test "a batch holds at most edge_per_batch stores, in head order, and the rest wait in place" do
    stores = for i <- 1..20, do: store(i)
    plains = for i <- 1..10, do: plain(i)
    for item <- stores ++ plains, do: :ok = WorkQueue.enqueue(item, force: true)
    cap = WorkQueue.edge_per_batch()
    assert cap == 8

    got = names(GenServer.call(WorkQueue, {:dequeue, 15}))
    assert length(got) == 15
    assert Enum.count(got, &(prefix(&1) == "s")) == cap
    # The first eight stores and the first seven plain names, in the order they were queued.
    assert got == Enum.map(Enum.take(stores, cap) ++ Enum.take(plains, 7), & &1.ctl_domain)

    # The skipped stores are still at the head: the next batch gets the next eight, then the plain tail.
    got2 = names(GenServer.call(WorkQueue, {:dequeue, 15}))
    assert got2 == Enum.map(Enum.slice(stores, cap, cap) ++ Enum.drop(plains, 7), & &1.ctl_domain)

    # Only stores left: a batch is the cap, never a choked run.
    got3 = names(GenServer.call(WorkQueue, {:dequeue, 15}))
    assert got3 == Enum.map(Enum.drop(stores, 2 * cap), & &1.ctl_domain)
    assert length(got3) == 4
    assert GenServer.call(WorkQueue, {:dequeue, 15}) == {:empty, []}
  end

  test "the cap counts across tier A and discovery: a run of stores in both lanes still fits one batch" do
    for i <- 1..10, do: :ok = WorkQueue.enqueue(store(i), force: true)
    for i <- 1..10, do: :ok = WorkQueue.enqueue(Map.put(new(i), :edge, true))
    for i <- 11..20, do: :ok = WorkQueue.enqueue(new(i))

    got = names(GenServer.call(WorkQueue, {:dequeue, 20}))
    assert Enum.count(got, &(prefix(&1) == "s")) == 8
    assert Enum.count(got, &(prefix(&1) == "n")) == 10
    assert length(got) == 18
    # Stores from the queue's priority share come first, then the untagged discovery names.
    assert Enum.take(got, 8) |> Enum.all?(&(prefix(&1) == "s"))
  end

  test "only the literal edge: true counts; hostile tags leave a name untouched by the cap" do
    refute WorkQueue.edge?(%{ctl_domain: "x.test", edge: "true"})
    refute WorkQueue.edge?(%{ctl_domain: "x.test", edge: 1})
    refute WorkQueue.edge?(%{ctl_domain: "x.test", edge: nil})
    refute WorkQueue.edge?(%{ctl_domain: "x.test"})
    refute WorkQueue.edge?(nil)
    refute WorkQueue.edge?("edge: true")
    assert WorkQueue.edge?(%{ctl_domain: "x.test", edge: true})

    for i <- 1..12, do: :ok = WorkQueue.enqueue(Map.put(plain(i), :edge, "true"), force: true)
    got = names(GenServer.call(WorkQueue, {:dequeue, 12}))
    assert length(got) == 12
  end

  test "a requeued batch keeps the tag, so a returned run is still capped" do
    for i <- 1..12, do: :ok = WorkQueue.enqueue(store(i), force: true)
    {:ok, bid, items} = GenServer.call(WorkQueue, {:dequeue, 12})
    assert length(items) == 8
    GenServer.cast(WorkQueue, {:complete, bid, []})
    _ = WorkQueue.stats()
    :ok = WorkQueue.requeue(items, :tail)
    _ = WorkQueue.stats()
    assert WorkQueue.stats().queue_depth == 12

    {:ok, _bid, again} = GenServer.call(WorkQueue, {:dequeue, 12})
    assert length(again) == 8
    assert Enum.all?(again, &WorkQueue.edge?/1)
  end

  describe "the worker tags what it hands back" do
    test "a store cut by the deadline goes back with edge: true, a plain site goes back as it was" do
      item = %{ctl_domain: "store.test", source: :recrawl, tier: "a"}
      assert WorkerAgent.edge_tag(item, "23.227.38.65") == Map.put(item, :edge, true)
      assert WorkerAgent.edge_tag(item, "93.184.216.34") == item
      assert WorkerAgent.edge_tag(item, nil) == item
      assert WorkerAgent.edge_tag(item, "") == item
      assert WorkerAgent.edge_tag(item, :no_ip) == item
      assert WorkerAgent.edge_tag(:not_a_map, "23.227.38.65") == :not_a_map
    end

    test "the worker's return path and the scheduler's Shopify list both carry the tag" do
      worker = File.read!("lib/ls/cluster/worker_agent.ex")
      assert worker =~ "for({d, ip} <- cut, item = by_domain[d], do: edge_tag(item, ip))"
      assert worker =~ "|> Map.put(:after_429, true) |> edge_tag(ip)"

      scheduler = File.read!("lib/ls/recrawl/scheduler.ex")
      assert scheduler =~ "|> edge_tag(shopify)"
      assert scheduler =~ "defp edge_tag(data, true), do: Map.put(data, :edge, true)"
    end
  end
end
