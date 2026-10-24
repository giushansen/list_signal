defmodule LS.Cluster.WorkQueuePriorityLaneTest do
  @moduledoc """
  2026-10-24. Two things the queue did not do, and what each cost:

  * No priority. Tier A refreshes (the changes customers pay for) waited
    behind 400K certificate sightings, and the scheduler had paused them
    outright for 12 hours because the queue was over its headroom. Tier A
    now dequeues first.
  * No heartbeat. A batch that ran 11 to 22 minutes was requeued at the
    10-minute in-flight timeout while the worker was still fetching it, and
    a second node fetched the same sites: 221,932 of 444,252 rows in a day
    were duplicates, the two-IP pattern of the 2026-08-28 abuse report. A
    heartbeating batch is never requeued.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue

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
        drain()

      {:empty, []} ->
        :ok
    end
  end

  defp names({:ok, _bid, items}), do: Enum.map(items, &(Map.get(&1, :ctl_domain) || Map.get(&1, :domain)))

  describe "priority" do
    test "a tier A refresh is 0, everything else is 1" do
      assert WorkQueue.priority(%{ctl_domain: "shop.com", source: :recrawl, tier: "a"}) == 0
      assert WorkQueue.priority(%{ctl_domain: "x.com", source: :recrawl, tier: "b"}) == 1
      assert WorkQueue.priority(%{ctl_domain: "x.com", source: :recrawl, tier: "c"}) == 1
      assert WorkQueue.priority(%{ctl_domain: "new.com", source: :ctl}) == 1
      assert WorkQueue.priority(%{ctl_domain: "bare.com"}) == 1
      # Hostile shapes never crash the enqueue path.
      assert WorkQueue.priority(%{}) == 1
      assert WorkQueue.priority(%{tier: "a"}) == 1
    end

    test "a tier A refresh enqueued last is dequeued first" do
      for i <- 1..5, do: :ok = WorkQueue.enqueue(%{ctl_domain: "ctl#{i}.test", source: :ctl})
      :ok = WorkQueue.enqueue(%{ctl_domain: "tiera.test", source: :recrawl, tier: "a", prev_simhash: 0}, force: true)
      :ok = WorkQueue.enqueue(%{ctl_domain: "tierb.test", source: :recrawl, tier: "b", prev_simhash: 0}, force: true)

      got = GenServer.call(WorkQueue, {:dequeue, 7})
      assert names(got) == ["tiera.test", "ctl1.test", "ctl2.test", "ctl3.test", "ctl4.test", "ctl5.test", "tierb.test"]
      assert WorkQueue.stats().queue_depth_priority == 0
    end

    test "stats count the tier A items still waiting" do
      :ok = WorkQueue.enqueue(%{ctl_domain: "a1.test", source: :recrawl, tier: "a"}, force: true)
      :ok = WorkQueue.enqueue(%{ctl_domain: "a2.test", source: :recrawl, tier: "a"}, force: true)
      :ok = WorkQueue.enqueue(%{ctl_domain: "n1.test", source: :ctl})
      assert WorkQueue.stats().queue_depth_priority == 2
      assert WorkQueue.stats().queue_depth == 3
    end
  end

  describe "requeue from a worker" do
    test "surplus goes to the front of its priority, cut candidates to the tail" do
      for i <- 1..3, do: :ok = WorkQueue.enqueue(%{ctl_domain: "waiting#{i}.test", source: :ctl})
      WorkQueue.requeue(WorkQueue, [%{ctl_domain: "surplus.test", source: :ctl}], :front)
      WorkQueue.requeue(WorkQueue, [%{ctl_domain: "cut.test", source: :ctl}], :tail)
      # casts: make sure they landed before dequeuing
      _ = WorkQueue.stats()

      got = GenServer.call(WorkQueue, {:dequeue, 10})
      assert names(got) == ["surplus.test", "waiting1.test", "waiting2.test", "waiting3.test", "cut.test"]
    end

    test "a returned tier A item keeps its lane" do
      :ok = WorkQueue.enqueue(%{ctl_domain: "ctl.test", source: :ctl})
      WorkQueue.requeue(WorkQueue, [%{ctl_domain: "a-back.test", source: :recrawl, tier: "a"}], :tail)
      _ = WorkQueue.stats()
      assert names(GenServer.call(WorkQueue, {:dequeue, 10})) == ["a-back.test", "ctl.test"]
    end

    test "returned items are counted, hostile ones ignored, and the queue survives" do
      before = WorkQueue.stats()
      WorkQueue.requeue(WorkQueue, [%{ctl_domain: "ok.test"}, %{}, "junk", nil, %{domain: "legacy.test"}], :front)
      WorkQueue.requeue(WorkQueue, [], :tail)
      after_ = WorkQueue.stats()
      assert after_.total_returned_front - before.total_returned_front == 2
      assert after_.total_returned_tail == before.total_returned_tail
      assert names(GenServer.call(WorkQueue, {:dequeue, 10})) |> Enum.sort() == ["legacy.test", "ok.test"]
    end

    test "an unknown cast is dropped, never a crash of the queue every worker depends on" do
      pid = GenServer.whereis(WorkQueue)
      GenServer.cast(WorkQueue, {:from_a_future_release, 1, 2, 3})
      assert WorkQueue.stats().queue_depth == 0
      assert Process.alive?(pid)
      assert GenServer.whereis(WorkQueue) == pid
    end
  end

  describe "heartbeat and the in-flight timeout" do
    defp backdate(batch_id, ms_ago) do
      true = :ets.update_element(:work_inflight, batch_id, {3, System.system_time(:millisecond) - ms_ago})
    end

    test "the timeout judgement is pure and counts from the last beat" do
      now = 1_000_000
      assert WorkQueue.timed_out?(now - WorkQueue.batch_timeout_ms(), now)
      refute WorkQueue.timed_out?(now - WorkQueue.batch_timeout_ms() + 1, now)
      refute WorkQueue.timed_out?(now, now)
    end

    test "a batch nobody heartbeats is requeued after the timeout" do
      :ok = WorkQueue.enqueue(%{ctl_domain: "silent.test", source: :ctl})
      {:ok, bid, _} = GenServer.call(WorkQueue, {:dequeue, 1})
      backdate(bid, WorkQueue.batch_timeout_ms() + 1_000)
      before = WorkQueue.stats().total_requeued

      send(GenServer.whereis(WorkQueue), :check_inflight)
      assert WorkQueue.stats().total_requeued == before + 1
      assert names(GenServer.call(WorkQueue, {:dequeue, 1})) == ["silent.test"]
    end

    test "a heartbeating batch is never requeued while it runs" do
      :ok = WorkQueue.enqueue(%{ctl_domain: "alive.test", source: :ctl})
      {:ok, bid, _} = GenServer.call(WorkQueue, {:dequeue, 1})
      backdate(bid, WorkQueue.batch_timeout_ms() + 1_000)
      # The worker beats just before the sweep: the clock restarts.
      WorkQueue.heartbeat(WorkQueue, bid)
      before = WorkQueue.stats()

      send(GenServer.whereis(WorkQueue), :check_inflight)
      after_ = WorkQueue.stats()
      assert after_.total_requeued == before.total_requeued
      assert after_.total_heartbeats >= 1
      assert after_.inflight_batches == before.inflight_batches
      assert {:empty, []} = GenServer.call(WorkQueue, {:dequeue, 1})
      GenServer.cast(WorkQueue, {:complete, bid, []})
    end

    test "a heartbeat for a batch that already completed is ignored" do
      :ok = WorkQueue.enqueue(%{ctl_domain: "done.test", source: :ctl})
      {:ok, bid, _} = GenServer.call(WorkQueue, {:dequeue, 1})
      GenServer.cast(WorkQueue, {:complete, bid, []})
      before = WorkQueue.stats().total_heartbeats
      WorkQueue.heartbeat(WorkQueue, bid)
      WorkQueue.heartbeat(WorkQueue, -42)
      assert WorkQueue.stats().total_heartbeats == before
    end
  end
end
