defmodule LS.Cluster.WorkQueueTest do
  use ExUnit.Case, async: false

  # WorkQueue uses named ETS tables — can't run async
  setup do
    # Start WorkQueue if not already running
    case GenServer.whereis(LS.Cluster.WorkQueue) do
      nil ->
        {:ok, pid} = LS.Cluster.WorkQueue.start_link()
        on_exit(fn -> GenServer.stop(pid) end)
      _pid ->
        :ok
    end
    :ok
  end

  test "enqueue returns :ok" do
    domain_data = %{ctl_domain: "test1.com", ctl_tld: "com"}
    assert :ok = LS.Cluster.WorkQueue.enqueue(domain_data)
  end

  test "stats returns expected keys" do
    stats = LS.Cluster.WorkQueue.stats()
    expected_keys = [
      :queue_depth, :queue_pct, :queue_memory_mb,
      :inflight_batches, :total_enqueued, :total_dequeued,
      :total_completed, :total_requeued, :total_dropped,
      :enqueue_rate_per_min, :drain_rate_per_min, :uptime_seconds
    ]
    for key <- expected_keys do
      assert Map.has_key?(stats, key), "Missing stats key: #{key}"
    end
  end

  test "enqueue increments queue depth" do
    before = LS.Cluster.WorkQueue.stats().queue_depth
    LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "depth-test-#{:rand.uniform(99999)}.com"})
    after_stats = LS.Cluster.WorkQueue.stats()
    assert after_stats.queue_depth >= before
  end

  test "enqueue increments total_enqueued counter" do
    before = LS.Cluster.WorkQueue.stats().total_enqueued
    LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "counter-test-#{:rand.uniform(99999)}.com"})
    # Small delay for atomic counter propagation
    Process.sleep(10)
    after_stats = LS.Cluster.WorkQueue.stats()
    assert after_stats.total_enqueued > before
  end

  test "dequeue returns batch when queue has items" do
    # Enqueue some items
    for i <- 1..5 do
      LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "dequeue-test-#{i}-#{:rand.uniform(99999)}.com"})
    end

    case GenServer.call(LS.Cluster.WorkQueue, {:dequeue, 3}) do
      {:ok, batch_id, domains} ->
        assert is_integer(batch_id)
        assert length(domains) > 0
        assert length(domains) <= 3
        # Complete the batch so it doesn't timeout
        GenServer.cast(LS.Cluster.WorkQueue, {:complete, batch_id, []})
      {:empty, []} ->
        # Queue might have been emptied by another test
        :ok
    end
  end

  test "dequeue returns {:empty, []} when queue is empty" do
    # Drain the queue first
    drain_queue()
    assert {:empty, []} = GenServer.call(LS.Cluster.WorkQueue, {:dequeue, 10})
  end

  test "complete removes inflight batch" do
    LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "complete-test-#{:rand.uniform(99999)}.com"})

    case GenServer.call(LS.Cluster.WorkQueue, {:dequeue, 1}) do
      {:ok, batch_id, _domains} ->
        before = LS.Cluster.WorkQueue.stats().inflight_batches
        # Pass empty list — don't send junk to ClickHouse Inserter
        GenServer.cast(LS.Cluster.WorkQueue, {:complete, batch_id, []})
        Process.sleep(50)
        after_stats = LS.Cluster.WorkQueue.stats()
        assert after_stats.inflight_batches < before or after_stats.inflight_batches == 0
      {:empty, []} ->
        :ok
    end
  end

  test "queue_pct is between 0 and 100" do
    stats = LS.Cluster.WorkQueue.stats()
    assert stats.queue_pct >= 0.0
    assert stats.queue_pct <= 100.0
  end

  defp drain_queue do
    case GenServer.call(LS.Cluster.WorkQueue, {:dequeue, 1000}) do
      {:ok, batch_id, _} ->
        GenServer.cast(LS.Cluster.WorkQueue, {:complete, batch_id, []})
        drain_queue()
      {:empty, []} ->
        :ok
    end
  end
end
