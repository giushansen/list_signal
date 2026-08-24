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
  @counter_table :work_queue_counters
  # Default cap; override with LS_QUEUE_MAX (read once at init). Measured cost
  # ~287 B/item (273 MB at 1M), so 3M on the 16 GB master is ~800 MB.
  @max_queue_size 1_000_000
  defp max_queue_size, do: :persistent_term.get({__MODULE__, :max_queue_size}, @max_queue_size)
  @batch_timeout_ms 600_000        # 10 minutes
  @ttl_ms 86_400_000               # 24 hours
  @cleanup_interval_ms 3_600_000   # 1 hour
  @inflight_check_ms 60_000        # 1 minute

  # Counter indices
  @rate_window_ms 20_000
  @idx_enqueued 1
  @idx_dropped 2

  # ==========================================================================
  # CLIENT API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue one domain for enrichment. Returns `:ok` or `:queue_full`.

  Callers are the CT pipeline and `LS.Recrawl.Scheduler`. The map MUST carry
  the domain under `:ctl_domain` (recrawl items without it once crash-looped
  every worker — see commit 4f486ca):

      WorkQueue.enqueue(%{ctl_domain: "shop.example", source: :ctl})

  `:queue_full` is deliberate load-shedding, not an error: when CT inflow
  outruns the fleet, we drop discoveries rather than grow unbounded (the cap
  and the drop counter are visible in `stats/0`).
  """
  @spec enqueue(map()) :: :ok | :queue_full
  def enqueue(domain_data) when is_map(domain_data) do
    current_size = :ets.info(@queue_table, :size)

    if current_size >= max_queue_size() do
      :counters.add(counter_ref(), @idx_dropped, 1)
      :queue_full
    else
      id = :erlang.unique_integer([:monotonic, :positive])
      now = System.system_time(:millisecond)
      :ets.insert(@queue_table, {id, domain_data, now})
      :counters.add(counter_ref(), @idx_enqueued, 1)
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

    # Atomic counters for enqueue/dropped (called outside GenServer)
    ref = :counters.new(2, [:write_concurrency])
    :persistent_term.put(@counter_table, ref)

    schedule_cleanup()
    schedule_inflight_check()
    Process.send_after(self(), :sample_rates, @rate_window_ms)

    max = case Integer.parse(System.get_env("LS_QUEUE_MAX", "")) do
      {n, _} when n > 0 -> n
      _ -> @max_queue_size
    end
    :persistent_term.put({__MODULE__, :max_queue_size}, max)
    Logger.info("📋 WorkQueue started (max: #{Float.round(max / 1_000_000, 1)}M, TTL: 24h)")

    {:ok, %{
      total_dequeued: 0,
      total_completed: 0,
      total_requeued: 0,
      start_time: System.monotonic_time(:second),
      # Trailing-window rates (not lifetime averages) — truthful right after a
      # restart. rate_sample = {mono_seconds, enqueued_then, completed_then}.
      rate_sample: {System.monotonic_time(:second), 0, 0},
      enqueue_rate_win: 0.0,
      drain_rate_win: 0.0
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

    # Read atomic counters
    ref = counter_ref()
    total_enqueued = :counters.get(ref, @idx_enqueued)
    total_dropped = :counters.get(ref, @idx_dropped)

    # Lifetime averages kept for reference; the dashboard uses the windowed rates
    # below (total/uptime lied for hours after every restart — cold dedup cache
    # burst + averaging).
    drain_rate_lifetime = if uptime > 0, do: Float.round(state.total_completed / uptime * 60, 1), else: 0.0
    enqueue_rate_lifetime = if uptime > 0, do: Float.round(total_enqueued / uptime * 60, 1), else: 0.0

    stats = %{
      queue_depth: queue_size,
      queue_pct: if(max_queue_size() > 0, do: Float.round(queue_size / max_queue_size() * 100, 1), else: 0.0),
      queue_max: max_queue_size(),
      queue_memory_mb: queue_mem_mb,
      inflight_batches: inflight_count,
      total_enqueued: total_enqueued,
      total_dequeued: state.total_dequeued,
      total_completed: state.total_completed,
      total_requeued: state.total_requeued,
      total_dropped: total_dropped,
      enqueue_rate_per_min: state.enqueue_rate_win,
      drain_rate_per_min: state.drain_rate_win,
      enqueue_rate_lifetime: enqueue_rate_lifetime,
      drain_rate_lifetime: drain_rate_lifetime,
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
  # Recompute enqueue/drain rates over the trailing window and re-anchor.
  @impl true
  def handle_info(:sample_rates, state) do
    now = System.monotonic_time(:second)
    enq_now = :counters.get(counter_ref(), @idx_enqueued)
    comp_now = state.total_completed
    {t0, enq0, comp0} = state.rate_sample
    dt = now - t0

    {eqr, dr} =
      if dt > 0 do
        {Float.round((enq_now - enq0) / dt * 60, 1), Float.round((comp_now - comp0) / dt * 60, 1)}
      else
        {state.enqueue_rate_win, state.drain_rate_win}
      end

    Process.send_after(self(), :sample_rates, @rate_window_ms)
    {:noreply, %{state | rate_sample: {now, enq_now, comp_now}, enqueue_rate_win: eqr, drain_rate_win: dr}}
  end

  @impl true
  def handle_info(:cleanup_ttl, state) do
    cutoff = System.system_time(:millisecond) - @ttl_ms
    dropped = cleanup_expired(cutoff)

    if dropped > 0 do
      Logger.info("🧹 WorkQueue TTL cleanup: dropped #{dropped} stale domains")
    end

    schedule_cleanup()
    {:noreply, state}
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

  defp counter_ref do
    :persistent_term.get(@counter_table)
  end

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
