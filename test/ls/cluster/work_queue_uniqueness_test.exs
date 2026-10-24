defmodule LS.Cluster.WorkQueueUniquenessTest do
  @moduledoc """
  2026-10-24, two hours after tier A got its priority lane: 2,180 known
  businesses were fetched twice by two different nodes 10 to 60 minutes
  apart. A tier B refresh item was still waiting behind discovery when the
  next scheduler tick selected the same business again, and nothing in the
  queue knew it already held that domain. The owner's rule: a domain is
  never fetched twice on a node, and never queued twice across the fleet.
  The queue now keeps one row per domain, queued or in flight, and refuses
  a second copy whoever asks and whatever `force` says.
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
        _ = WorkQueue.stats()
        drain()

      {:empty, []} ->
        :ok
    end
  end

  defp uniq, do: "u#{System.unique_integer([:positive])}.test"

  test "the same domain cannot be queued twice, not even by the scheduler's force" do
    d = uniq()
    assert :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :ctl})
    assert :already_queued = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "a"}, force: true)
    # A plain repeat is caught earlier by the daily ring; either way, one copy.
    assert WorkQueue.enqueue(%{ctl_domain: d, source: :ctl}) in [:already_queued, :recently_crawled]
    assert WorkQueue.queued?(d)
    {:ok, bid, items} = GenServer.call(WorkQueue, {:dequeue, 10})
    assert Enum.count(items, &(&1.ctl_domain == d)) == 1
    GenServer.cast(WorkQueue, {:complete, bid, []})
  end

  test "a domain in flight on a worker is not re-admitted until its batch completes" do
    d = uniq()
    :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "b"}, force: true)
    {:ok, bid, [_]} = GenServer.call(WorkQueue, {:dequeue, 1})
    assert WorkQueue.queued?(d)
    assert :already_queued = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "b"}, force: true)

    GenServer.cast(WorkQueue, {:complete, bid, [%{domain: d, http_status: 200}], %{}})
    _ = WorkQueue.stats()
    refute WorkQueue.queued?(d)
    assert :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "b"}, force: true)
  end

  test "a batch the timeout requeues keeps its domains reserved, and a completed one releases them" do
    d = uniq()
    :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :ctl})
    {:ok, bid, _} = GenServer.call(WorkQueue, {:dequeue, 1})
    true = :ets.update_element(:work_inflight, bid, {3, System.system_time(:millisecond) - WorkQueue.batch_timeout_ms() - 1})
    send(GenServer.whereis(WorkQueue), :check_inflight)
    _ = WorkQueue.stats()
    assert WorkQueue.queued?(d)
    assert :already_queued = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "c"}, force: true)
    {:ok, bid2, [%{ctl_domain: ^d}]} = GenServer.call(WorkQueue, {:dequeue, 1})
    GenServer.cast(WorkQueue, {:complete, bid2, []})
    _ = WorkQueue.stats()
    refute WorkQueue.queued?(d)
  end

  test "a failed batch puts its domains back, still reserved" do
    d = uniq()
    :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :ctl})
    {:ok, bid, _} = GenServer.call(WorkQueue, {:dequeue, 1})
    GenServer.cast(WorkQueue, {:fail, bid})
    _ = WorkQueue.stats()
    assert WorkQueue.queued?(d)
    assert :already_queued = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "c"}, force: true)
  end

  test "a worker returning surplus does not duplicate a domain something else queued meanwhile" do
    d = uniq()
    :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :ctl})
    {:ok, bid, [item]} = GenServer.call(WorkQueue, {:dequeue, 1})
    # The worker's complete releases the batch, then the surplus comes back.
    GenServer.cast(WorkQueue, {:complete, bid, [], %{}})
    WorkQueue.requeue(WorkQueue, [item], :front)
    _ = WorkQueue.stats()
    assert WorkQueue.stats().queue_depth == 1
    # Returned again while already queued: refused, counted, one copy stays.
    before = WorkQueue.stats().total_already_queued
    WorkQueue.requeue(WorkQueue, [item], :tail)
    _ = WorkQueue.stats()
    assert WorkQueue.stats().queue_depth == 1
    assert WorkQueue.stats().total_already_queued == before + 1
  end

  test "an item that ages past the TTL frees its domain" do
    d = uniq()
    :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :ctl})
    [{key, data, _ts}] = :ets.select(:work_queue, [{{:_, %{ctl_domain: d}, :_}, [], [:"$_"]}])
    :ets.insert(:work_queue, {key, data, System.system_time(:millisecond) - 25 * 3_600_000})
    send(GenServer.whereis(WorkQueue), :cleanup_ttl)
    _ = WorkQueue.stats()
    refute WorkQueue.queued?(d)
    # The daily ring still remembers the first enqueue; the schedule may ask again.
    assert :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :recrawl, tier: "c"}, force: true)
  end

  test "the sweep drops an index row with no item behind it, so nothing is blocked for good" do
    d = uniq()
    :ets.insert(:work_queue_index, {d, :queued})
    assert WorkQueue.queued?(d)
    assert WorkQueue.reconcile_index() >= 1
    refute WorkQueue.queued?(d)
    assert :ok = WorkQueue.enqueue(%{ctl_domain: d, source: :ctl})
    assert WorkQueue.reconcile_index() == 0
  end

  test "the index is reported and matches the queue plus in-flight items" do
    for _ <- 1..3, do: :ok = WorkQueue.enqueue(%{ctl_domain: uniq(), source: :ctl})
    {:ok, bid, _} = GenServer.call(WorkQueue, {:dequeue, 1})
    s = WorkQueue.stats()
    # Other test modules may have left batches in flight; count them.
    inflight = :ets.foldl(fn {_b, items, _t}, n -> n + length(items) end, 0, :work_inflight)
    assert s.queue_index_size == s.queue_depth + inflight
    assert Map.has_key?(s, :total_already_queued)
    GenServer.cast(WorkQueue, {:complete, bid, []})
  end

  test "hostile shapes are not indexed and do not crash" do
    assert WorkQueue.queued?(nil) == false
    assert WorkQueue.queued?("") == false
    assert WorkQueue.queued?(123) == false
    WorkQueue.requeue(WorkQueue, [%{}, %{ctl_domain: ""}, "x"], :front)
    _ = WorkQueue.stats()
  end
end
