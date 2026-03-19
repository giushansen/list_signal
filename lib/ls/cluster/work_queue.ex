defmodule LS.Cluster.WorkQueue do
  @moduledoc """
  ETS-backed work queue for distributing enrichment work to workers.

  Runs on the master node only. Workers pull batches via:

      GenServer.call({LS.Cluster.WorkQueue, :master_node}, {:dequeue, 1000})

  ## Queue flow

      CTL Poller → ctl_track returns :new → enqueue(domain_data)
                                   :tracked → skip (already queued)

  ## Protections

  - Hard cap: max 5M domains in queue (~600MB RAM)
  - TTL eviction: domains older than 24h get dropped hourly
  - In-flight tracking: timed-out batches get requeued after 10min

  ## Stats

      LS.Cluster.WorkQueue.stats()
  """

  use GenServer
  require Logger

  @queue_table :work_queue
  @inflight_table :work_inflight
  @max_queue_size 5_000_000
  @batch_timeout_ms 600_000        # 10 minutes
  @ttl_ms 86_400_000               # 24 hours
  @cleanup_interval_ms 3_600_000   # 1 hour
  @inflight_check_ms 60_000        # 1 minute

  # ==========================================================================
  # CLIENT API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Enqueue a domain for enrichment. Called by CTL pipeline on :new domains."
  def enqueue(domain_data) when is_map(domain_data) do
    current_size = :ets.info(@queue_table, :size)

    if current_size >= @max_queue_size do
      :queue_full
    else
      id = :erlang.unique_integer([:monotonic, :positive])
      now = System.system_time(:millisecond)
      :ets.insert(@queue_table, {id, domain_data, now})
      :ok
    end
  end

  @doc "Dequeue a batch of domains. Called by workers."
  def dequeue(count) do
    GenServer.call(__MODULE__, {:dequeue, count}, 10_000)
  end

  @doc "Return completed results. Called by workers after enrichment."
  def complete(batch_id, results) do
    GenServer.cast(__MODULE__, {:complete, batch_id, results})
  end

  @doc "Return failed batch for requeue. Called by workers on crash."
  def fail(batch_id) do
    GenServer.cast(__MODULE__, {:fail, batch_id})
  end

  @doc "Get queue statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ==========================================================================
  # GENSERVER
  # ==========================================================================

  @impl true
  def init(_opts) do
    :ets.new(@queue_table, [:ordered_set, :public, :named_table,
      read_concurrency: true, write_concurrency: true])
    :ets.new(@inflight_table, [:set, :public, :named_table])

    schedule_cleanup()
    schedule_inflight_check()

    Logger.info("📋 WorkQueue started (max: #{div(@max_queue_size, 1_000_000)}M, TTL: 24h)")

    {:ok, %{
      total_enqueued: 0,
      total_dequeued: 0,
      total_completed: 0,
      total_requeued: 0,
      total_dropped: 0,
      start_time: System.monotonic_time(:second)
    }}
  end

  @impl true
  def handle_call({:dequeue, count}, _from, state) do
    now = System.system_time(:millisecond)
    batch = take_batch(count)

    case batch do
      [] ->
        {:reply, {:empty, []}, state}

      items ->
        batch_id = :erlang.unique_integer([:monotonic, :positive])
        domains = Enum.map(items, fn {_id, data, _ts} -> data end)

        # Track in-flight
        :ets.insert(@inflight_table, {batch_id, items, now})

        {:reply, {:ok, batch_id, domains},
          %{state | total_dequeued: state.total_dequeued + length(items)}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time
    queue_size = :ets.info(@queue_table, :size)
    inflight_count = :ets.info(@inflight_table, :size)

    queue_mem_words = :ets.info(@queue_table, :memory) || 0
    queue_mem_mb = Float.round(queue_mem_words * :erlang.system_info(:wordsize) / 1_048_576, 1)

    drain_rate = if uptime > 0,
      do: Float.round(state.total_completed / uptime * 60, 1),
      else: 0.0

    enqueue_rate = if uptime > 0,
      do: Float.round(state.total_enqueued / uptime * 60, 1),
      else: 0.0

    stats = %{
      queue_depth: queue_size,
      queue_pct: if(@max_queue_size > 0, do: Float.round(queue_size / @max_queue_size * 100, 1), else: 0.0),
      queue_memory_mb: queue_mem_mb,
      inflight_batches: inflight_count,
      total_enqueued: state.total_enqueued,
      total_dequeued: state.total_dequeued,
      total_completed: state.total_completed,
      total_requeued: state.total_requeued,
      total_dropped: state.total_dropped,
      enqueue_rate_per_min: enqueue_rate,
      drain_rate_per_min: drain_rate,
      uptime_seconds: uptime
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast({:complete, batch_id, results}, state) do
    :ets.delete(@inflight_table, batch_id)

    # Forward to inserter
    LS.Cluster.Inserter.insert(results)

    {:noreply, %{state | total_completed: state.total_completed + length(results)}}
  end

  @impl true
  def handle_cast({:fail, batch_id}, state) do
    case :ets.lookup(@inflight_table, batch_id) do
      [{^batch_id, items, _started_at}] ->
        :ets.delete(@inflight_table, batch_id)
        # Requeue all items
        now = System.system_time(:millisecond)
        Enum.each(items, fn {_old_id, data, _old_ts} ->
          new_id = :erlang.unique_integer([:monotonic, :positive])
          :ets.insert(@queue_table, {new_id, data, now})
        end)
        {:noreply, %{state | total_requeued: state.total_requeued + length(items)}}

      [] ->
        {:noreply, state}
    end
  end

  # TTL cleanup — drop domains older than 24h
  @impl true
  def handle_info(:cleanup_ttl, state) do
    cutoff = System.system_time(:millisecond) - @ttl_ms
    dropped = cleanup_expired(cutoff)

    if dropped > 0 do
      Logger.info("🧹 WorkQueue TTL cleanup: dropped #{dropped} stale domains")
    end

    schedule_cleanup()
    {:noreply, %{state | total_dropped: state.total_dropped + dropped}}
  end

  # Requeue timed-out in-flight batches
  @impl true
  def handle_info(:check_inflight, state) do
    cutoff = System.system_time(:millisecond) - @batch_timeout_ms
    requeued = requeue_timed_out(cutoff)

    if requeued > 0 do
      Logger.warning("⏱️  Requeued #{requeued} timed-out in-flight domains")
    end

    schedule_inflight_check()
    {:noreply, %{state | total_requeued: state.total_requeued + requeued}}
  end

  # ==========================================================================
  # PRIVATE
  # ==========================================================================

  defp take_batch(count) do
    take_batch(count, [])
  end

  defp take_batch(0, acc), do: Enum.reverse(acc)
  defp take_batch(remaining, acc) do
    case :ets.first(@queue_table) do
      :"$end_of_table" ->
        Enum.reverse(acc)

      key ->
        case :ets.take(@queue_table, key) do
          [item] -> take_batch(remaining - 1, [item | acc])
          [] -> Enum.reverse(acc)
        end
    end
  end

  defp cleanup_expired(cutoff) do
    :ets.select_delete(@queue_table, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [true]}
    ])
  rescue
    _ -> 0
  end

  defp requeue_timed_out(cutoff) do
    now = System.system_time(:millisecond)

    timed_out = :ets.select(@inflight_table, [
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff}], [{{:"$1", :"$2"}}]}
    ])

    Enum.reduce(timed_out, 0, fn {batch_id, items}, count ->
      :ets.delete(@inflight_table, batch_id)
      Enum.each(items, fn {_old_id, data, _old_ts} ->
        new_id = :erlang.unique_integer([:monotonic, :positive])
        :ets.insert(@queue_table, {new_id, data, now})
      end)
      count + length(items)
    end)
  rescue
    _ -> 0
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_ttl, @cleanup_interval_ms)
  end

  defp schedule_inflight_check do
    Process.send_after(self(), :check_inflight, @inflight_check_ms)
  end
end
