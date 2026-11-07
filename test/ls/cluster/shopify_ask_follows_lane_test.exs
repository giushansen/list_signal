defmodule LS.Cluster.ShopifyAskFollowsLaneTest do
  @moduledoc """
  2026-11-07: the Shopify share of a batch was one number for every node
  and every hour (LS_EDGE_PER_BATCH, 8). Raising it to 16 for an hour on
  2026-11-05 changed nothing: the lane still served about eight stores a
  window, the other eight were cut at the deadline after their first
  requests were spent, and the nodes wrote 10% fewer rows. What a lane
  can serve moves with the node's budget lines, so the worker now asks
  for what its lane served last time (a pull), and the master holds any
  ask to a range.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue
  alias LS.Cluster.WorkerAgent

  @shopify "23.227.38.65"
  @plain "93.184.216.34"

  describe "the worker's ask" do
    test "a lane that served all it asked for asks for a quarter more, at least two" do
      assert WorkerAgent.next_edge_ask(8, %{offered: 8, tagged: 8, served: 8}) == 10
      assert WorkerAgent.next_edge_ask(20, %{offered: 22, tagged: 20, served: 22}) == 25
    end

    test "a lane that was cut asks for what it served less what DNS added, never more than before" do
      # 16 given, 8 served (the 2026-11-05 hour): back toward 8.
      assert WorkerAgent.next_edge_ask(16, %{offered: 16, tagged: 16, served: 8}) == 12
      assert WorkerAgent.next_edge_ask(12, %{offered: 12, tagged: 12, served: 8}) == 10
      # Three untagged stores found by DNS also took the lane's time.
      assert WorkerAgent.next_edge_ask(10, %{offered: 13, tagged: 10, served: 10}) == 8
      # A cut always lowers the ask, even when half the distance rounds back up.
      assert WorkerAgent.next_edge_ask(9, %{offered: 9, tagged: 9, served: 8}) == 8
    end

    test "a batch the master could not fill, or with no store at all, teaches nothing" do
      assert WorkerAgent.next_edge_ask(20, %{offered: 5, tagged: 5, served: 5}) == 20
      assert WorkerAgent.next_edge_ask(20, %{offered: 0, tagged: 0, served: 0}) == 20
    end

    test "the ask stays inside 2..48 whatever the stats say" do
      assert WorkerAgent.next_edge_ask(48, %{offered: 48, tagged: 48, served: 48}) == 48
      assert WorkerAgent.next_edge_ask(2, %{offered: 30, tagged: 2, served: 0}) == 2
      assert WorkerAgent.next_edge_ask(500, %{}) == 48
      assert WorkerAgent.next_edge_ask(-4, %{offered: 3}) == 2
      assert WorkerAgent.next_edge_ask(nil, nil) == WorkQueue.edge_per_batch()
      assert WorkerAgent.next_edge_ask(8, %{offered: "8", tagged: 8, served: 8}) == 8
    end
  end

  describe "the lane's stats" do
    test "served counts results that are not refusals; tagged counts what the master sent as stores" do
      cands = [{"a.test", @shopify}, {"b.test", @shopify}, {"c.test", @shopify}, {"d.test", @shopify}, {"p.test", @plain}]
      res = %{"a.test" => %{http_status: 200}, "b.test" => %{http_status: 429}, "c.test" => %{http_error: "rate_limited"}, "p.test" => %{http_status: 200}}
      by_domain = %{"a.test" => %{edge: true}, "b.test" => %{edge: true}, "c.test" => %{}, "d.test" => %{edge: true}, "p.test" => %{}}

      assert WorkerAgent.edge_stats(cands, res, by_domain) == %{offered: 4, tagged: 3, served: 1}
      assert WorkerAgent.edge_stats([], %{}, %{}) == %{offered: 0, tagged: 0, served: 0}
      # A candidate the batch knows nothing about is not a tagged store.
      assert WorkerAgent.edge_stats([{"x.test", @shopify}], %{}, %{}) == %{offered: 1, tagged: 0, served: 0}
    end
  end

  describe "the master" do
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

    test "a worker's ask sets how many stores its batch holds; the rest wait in place" do
      for item <- Enum.map(1..30, &store/1) ++ Enum.map(1..10, &plain/1), do: :ok = WorkQueue.enqueue(item, force: true)

      {:ok, bid, items} = GenServer.call(WorkQueue, {:dequeue, 40, 20})
      assert Enum.count(items, &WorkQueue.edge?/1) == 20
      assert Enum.count(items, &(not WorkQueue.edge?(&1))) == 10
      GenServer.cast(WorkQueue, {:complete, bid, []})
      assert WorkQueue.stats().queue_depth == 10
    end

    test "an ask out of range or not a number is held to the range or the default" do
      assert WorkQueue.bounded_ask(20) == 20
      assert WorkQueue.bounded_ask(0) == 1
      assert WorkQueue.bounded_ask(-5) == 1
      assert WorkQueue.bounded_ask(10_000) == 48
      assert WorkQueue.bounded_ask("40") == WorkQueue.edge_per_batch()
      assert WorkQueue.bounded_ask(nil) == WorkQueue.edge_per_batch()

      for item <- Enum.map(1..60, &store/1), do: :ok = WorkQueue.enqueue(item, force: true)
      {:ok, _bid, items} = GenServer.call(WorkQueue, {:dequeue, 100, 10_000})
      assert length(items) == 48
    end

    test "a worker that does not ask still gets the default cap" do
      for item <- Enum.map(1..12, &store/1), do: :ok = WorkQueue.enqueue(item, force: true)
      {:ok, _bid, items} = GenServer.call(WorkQueue, {:dequeue, 12})
      assert length(items) == WorkQueue.edge_per_batch()
    end
  end

  test "a worker asks only a master that reads the ask, so a worker deployed first cannot crash an old queue" do
    assert function_exported?(WorkQueue, :edge_ask_range, 0)
    src = File.read!("lib/ls/cluster/worker_agent.ex")
    assert src =~ "defp dequeue_msg(want, %{edge_asks?: true, edge_ask: ask}), do: {:dequeue, want, ask}"
    assert src =~ "defp dequeue_msg(want, _s), do: {:dequeue, want}"
    assert src =~ ":rpc.call(master, :erlang, :function_exported, [LS.Cluster.WorkQueue, :edge_ask_range, 0], 5_000) == true"
  end
end
