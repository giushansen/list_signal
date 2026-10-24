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
  - In-flight tracking: timed-out batches get requeued after 10min, unless
    the worker is still heartbeating for them (see below)

  ## Order (2026-10-24)

  The table is an ordered_set keyed by `{priority, id}`. Priority 0 is the
  refresh of a tier A business (`LS.Crawl.Tiers`: an online business with
  revenue, jobs or a catalogue), the rows customers pay to see change;
  everything else is 1. Within a priority the id is monotonic, so it is
  FIFO. A worker that dequeued more than its fetch budget can finish hands
  the surplus back with `requeue/2` to the FRONT of its priority (a negative
  monotonic id), so nothing it never touched waits a second time behind
  400K newer names.

  ## Heartbeat (2026-10-24)

  Workers cast `heartbeat/1` for a running batch every two minutes. The
  in-flight timeout only fires for a batch nobody is heartbeating. Before
  this, a batch that legitimately ran 11 to 22 minutes was requeued at 10,
  the worker finished it anyway, and a second node fetched the same 1,000
  sites again: 221,932 of 444,252 rows on 2026-10-23 were duplicates, the
  same two-IP pattern as the 2026-08-28 Vultr abuse report.

  ## Stats

      LS.Cluster.WorkQueue.stats()
  """

  use GenServer
  require Logger

  @queue_table :work_queue
  @inflight_table :work_inflight
  # Domains whose results were inserted recently. The requeue path consults it
  # so a timed-out batch never re-crawls what already succeeded, see
  # requeue_timed_out/1 and the 2026-08-28 Vultr abuse report.
  #
  # TTL is 3x @batch_timeout_ms, NOT hours: the only question this table ever
  # answers is "did this batch complete before its 10-minute in-flight timeout
  # fired", so nothing outside that window is ever consulted. Shipped at 6
  # hours by mistake — 36x more retention than the 10-minute question needs —
  # and at ~7,000 domains/min steady throughput that grew to ~1.2M rows within
  # 3 hours of a fresh boot, heading toward a ~2.3M-row plateau. Found
  # 2026-08-29 chasing a recurrence of the memory-limit stall this same
  # commit was supposed to prevent: the fix for one outage became a
  # contributor to the next.
  @recent_table :recently_crawled
  @recent_ttl_ms :timer.minutes(30)
  # Hard backstop independent of the TTL sweep, same philosophy as the
  # 2026-08-26 cache bounds: a burst that outruns the hourly sweep must not
  # be allowed to grow this without limit.
  @recent_max_entries 500_000
  @counter_table :work_queue_counters
  # Default cap; override with LS_QUEUE_MAX (read once at init). Measured cost
  # ~287 B/item (273 MB at 1M), so 3M on the 16 GB master is ~800 MB.
  @max_queue_size 1_000_000
  defp max_queue_size, do: :persistent_term.get({__MODULE__, :max_queue_size}, @max_queue_size)
  @batch_timeout_ms 600_000        # 10 minutes
  @ttl_ms 86_400_000               # 24 hours
  @cleanup_interval_ms 3_600_000   # 1 hour
  @inflight_check_ms 60_000        # 1 minute

  @doc "The in-flight timeout: a batch with no heartbeat for this long is requeued."
  def batch_timeout_ms, do: @batch_timeout_ms

  # Queue key priorities. 0 dequeues before 1.
  @prio_refresh_a 0
  @prio_default 1

  # Counter indices
  @rate_window_ms 20_000
  @idx_enqueued 1
  @idx_dropped 2
  @idx_deduped 3
  @idx_deduped_stable 4
  @idx_deduped_dormant 5
  @idx_deduped_tier 6

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
  and the drop counter are visible in `stats/0`). `:recently_crawled` means
  `LS.Cluster.CrawlDedup` saw this domain enqueued within its 3.5-7 day
  window and suppressed the repeat visit (counted as `total_deduped`).
  """
  @spec enqueue(map(), keyword()) :: :ok | :queue_full | :recently_crawled
  def enqueue(domain_data, opts \\ [])

  def enqueue(domain_data, opts) when is_map(domain_data) and is_list(opts) do
    current_size = :ets.info(@queue_table, :size)
    domain = domain_data[:ctl_domain] || domain_data[:domain]
    # A domain that just changed is back on the 7-day schedule whatever the
    # slower rings say (2026-10-01): revisit in proportion to change.
    hot = LS.Cluster.CrawlDedup.hot?(domain)

    cond do
      current_size >= max_queue_size() ->
        :counters.add(counter_ref(), @idx_dropped, 1)
        :queue_full

      # Dormant ring (2026-10-01): twice unchanged, or filtered on a verdict
      # the name settles. 60-90 days, not bypassed by force either.
      not hot and LS.Cluster.CrawlDedup.dormant?(domain) ->
        LS.Cluster.CrawlDedup.record_sighting(domain_data)
        :counters.add(counter_ref(), @idx_deduped_dormant, 1)
        :recently_crawled

      # Stable ring next, and NOT bypassed by force (2026-09-09): a domain
      # whose last crawl came back unchanged waits 28-35 days, whoever asks.
      # The recrawl scheduler's force only means "I am the 7-day schedule".
      not hot and LS.Cluster.CrawlDedup.stable?(domain) ->
        LS.Cluster.CrawlDedup.record_sighting(domain_data)
        :counters.add(counter_ref(), @idx_deduped_stable, 1)
        :recently_crawled

      # Refresh tiers (2026-10-03): a known tier B or C business waits its
      # cadence (60 or 120 days) before a certificate re-sighting can fetch
      # it again. The scheduler's force bypasses this ring, the way it
      # bypasses the daily one: it is the tier schedule.
      not hot and not Keyword.get(opts, :force, false) and LS.Cluster.CrawlDedup.tiered?(domain) ->
        LS.Cluster.CrawlDedup.record_sighting(domain_data)
        :counters.add(counter_ref(), @idx_deduped_tier, 1)
        :recently_crawled

      # 27.6% of all fetches were repeat visits inside a week (2026-09-04:
      # 62.3M crawls, 45.1M distinct domains) because the CTL cache holds
      # ~1h of inflow and every cert renewal re-emits from many CT logs.
      # CrawlDedup suppresses re-enqueues for 7-8 days (2026-09-06: eight
      # daily windows, was 3.5-7). `force: true` is for the recrawl
      # scheduler, which IS the 7-day schedule and must not be second-guessed
      # by a bloom that may still hold the entry on day 7. The requeue path
      # in requeue_timed_out/1 inserts into the ETS table directly, so a
      # timed-out batch is never blocked by its own enqueue-time entry. A
      # suppressed certificate sighting is still recorded (ctl_sightings).
      not Keyword.get(opts, :force, false) and
          LS.Cluster.CrawlDedup.seen_or_mark(domain_data[:ctl_domain] || domain_data[:domain]) ->
        LS.Cluster.CrawlDedup.record_sighting(domain_data)
        :counters.add(counter_ref(), @idx_deduped, 1)
        :recently_crawled

      true ->
        now = System.system_time(:millisecond)
        :ets.insert(@queue_table, {tail_key(domain_data), domain_data, now})
        :counters.add(counter_ref(), @idx_enqueued, 1)
        :ok
    end
  end

  @doc """
  Pure: where an item sorts. A tier A refresh (`source: :recrawl`, `tier:
  "a"`) is 0 and dequeues before everything else; the rest is 1. The
  scheduler marks tier A on the item, so the queue never has to look a
  domain up to know what it is.
  """
  @spec priority(map()) :: 0 | 1
  def priority(%{source: :recrawl, tier: "a"}), do: @prio_refresh_a
  def priority(%{"source" => :recrawl, "tier" => "a"}), do: @prio_refresh_a
  def priority(_), do: @prio_default

  @doc "Pure: a key that sorts after every item of the same priority already queued."
  @spec tail_key(map()) :: {0 | 1, integer()}
  def tail_key(data), do: {priority(data), :erlang.unique_integer([:monotonic, :positive])}

  @doc "Pure: a key that sorts before every item of the same priority already queued."
  @spec front_key(map()) :: {0 | 1, integer()}
  def front_key(data), do: {priority(data), -:erlang.unique_integer([:monotonic, :positive])}

  @doc """
  Hand items back from a worker. `:front` for domains the worker dequeued
  and never touched (over its fetch budget for the batch): they keep their
  place. `:tail` for domains whose fetch the stage deadline cut while in
  flight: they may have received a request, so they wait their turn again
  and a second contact is hours away, never minutes. No dedup check here,
  like `requeue_timed_out/1`: these items passed the gate when they were
  first enqueued.
  """
  @spec requeue(GenServer.server(), [map()], :front | :tail) :: :ok
  def requeue(server \\ __MODULE__, items, where) when is_list(items) and where in [:front, :tail] do
    if items != [], do: GenServer.cast(server, {:requeue, items, where})
    :ok
  end

  @doc "A worker says it is still working on this batch; resets its in-flight clock."
  @spec heartbeat(GenServer.server(), integer()) :: :ok
  def heartbeat(server \\ __MODULE__, batch_id), do: GenServer.cast(server, {:heartbeat, batch_id})

  @doc "Dequeue a batch of domains. Called by workers."
  def dequeue(count) do
    GenServer.call(__MODULE__, {:dequeue, count}, 10_000)
  end

  @doc "Return completed results. Called by workers after enrichment."
  def complete(batch_id, results) do
    GenServer.cast(__MODULE__, {:complete, batch_id, results})
  end

  @doc """
  Return completed results plus the batch's verdicts on domains that got
  no row (2026-10-01): `dormant` (name-settled skips), `soft` (no mail
  setup yet), `recent`, `unresolved`. The gate remembers them.
  """
  def complete(batch_id, results, skipped) when is_map(skipped) do
    GenServer.cast(__MODULE__, {:complete, batch_id, results, skipped})
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
    :ets.new(@recent_table, [:set, :public, :named_table, write_concurrency: true])

    # Atomic counters for enqueue/dropped (called outside GenServer)
    ref = :counters.new(6, [:write_concurrency])
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
      total_returned_front: 0,
      total_returned_tail: 0,
      total_heartbeats: 0,
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
    total_deduped = :counters.get(ref, @idx_deduped)
    total_deduped_stable = :counters.get(ref, @idx_deduped_stable)
    total_deduped_dormant = :counters.get(ref, @idx_deduped_dormant)
    total_deduped_tier = :counters.get(ref, @idx_deduped_tier)

    # Lifetime averages kept for reference; the dashboard uses the windowed rates
    # below (total/uptime lied for hours after every restart — cold dedup cache
    # burst + averaging).
    drain_rate_lifetime = if uptime > 0, do: Float.round(state.total_completed / uptime * 60, 1), else: 0.0
    enqueue_rate_lifetime = if uptime > 0, do: Float.round(total_enqueued / uptime * 60, 1), else: 0.0

    stats = %{
      queue_depth: queue_size,
      # Tier A refreshes waiting (priority 0). An ordered_set bounds the scan
      # to the matching key range.
      queue_depth_priority: :ets.select_count(@queue_table, [{{{@prio_refresh_a, :_}, :_, :_}, [], [true]}]),
      queue_pct: if(max_queue_size() > 0, do: Float.round(queue_size / max_queue_size() * 100, 1), else: 0.0),
      queue_max: max_queue_size(),
      queue_memory_mb: queue_mem_mb,
      inflight_batches: inflight_count,
      total_enqueued: total_enqueued,
      total_dequeued: state.total_dequeued,
      total_completed: state.total_completed,
      total_requeued: state.total_requeued,
      total_returned_front: state.total_returned_front,
      total_returned_tail: state.total_returned_tail,
      total_heartbeats: state.total_heartbeats,
      total_dropped: total_dropped,
      total_deduped: total_deduped,
      total_deduped_stable: total_deduped_stable,
      total_deduped_dormant: total_deduped_dormant,
      total_deduped_tier: total_deduped_tier,
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
    mark_recently_crawled(results)

    # Forward to inserter
    LS.Cluster.Inserter.insert(results)

    {:noreply, %{state | total_completed: state.total_completed + length(results)}}
  end

  def handle_cast({:complete, batch_id, results, skipped}, state) do
    :ets.delete(@inflight_table, batch_id)
    mark_recently_crawled(results)
    remember_skipped(skipped)
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
          :ets.insert(@queue_table, {tail_key(data), data, now})
        end)
        {:noreply, %{state | total_requeued: state.total_requeued + length(items)}}

      [] ->
        {:noreply, state}
    end
  end

  # A worker hands back what it dequeued and could not fetch this batch.
  def handle_cast({:requeue, items, where}, state) when is_list(items) do
    now = System.system_time(:millisecond)
    key = if where == :front, do: &front_key/1, else: &tail_key/1

    n =
      Enum.count(items, fn
        %{} = data when is_map_key(data, :ctl_domain) or is_map_key(data, :domain) ->
          :ets.insert(@queue_table, {key.(data), data, now})
          true

        _ ->
          false
      end)

    state =
      if where == :front,
        do: %{state | total_returned_front: state.total_returned_front + n},
        else: %{state | total_returned_tail: state.total_returned_tail + n}

    {:noreply, state}
  end

  # A running batch resets its in-flight clock. Unknown ids (already
  # completed, or requeued before the worker's first beat) are ignored.
  def handle_cast({:heartbeat, batch_id}, state) do
    now = System.system_time(:millisecond)

    case :ets.update_element(@inflight_table, batch_id, {3, now}) do
      true -> {:noreply, %{state | total_heartbeats: state.total_heartbeats + 1}}
      false -> {:noreply, state}
    end
  end

  # Anything else cast at the queue (an older or newer worker release) is
  # dropped, never a crash of the queue every worker depends on.
  def handle_cast(other, state) do
    Logger.warning("WorkQueue ignored cast #{inspect(other, limit: 3)}")
    {:noreply, state}
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
    sweep_recently_crawled()
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

  @doc false
  # Verdicts on domains that wrote no row: the name-settled ones sleep
  # 60-90 days, the mail-less ones 28-35, and all of them count as handled
  # so a late batch timeout does not send them to a second node.
  def remember_skipped(skipped) when is_map(skipped) do
    dormant = List.wrap(skipped[:dormant])
    soft = List.wrap(skipped[:soft])
    LS.Cluster.CrawlDedup.mark_dormant(dormant)
    LS.Cluster.CrawlDedup.mark_stable(soft)

    (dormant ++ soft ++ List.wrap(skipped[:recent]) ++ List.wrap(skipped[:unresolved]))
    |> Enum.map(&%{domain: &1})
    |> mark_recently_crawled()
  end

  def remember_skipped(_), do: :ok

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

      # Only re-crawl what did NOT complete. A batch can time out AFTER its
      # results were inserted (slow cycle, or the :complete cast lost to a
      # master restart or disconnect), and requeuing it wholesale sent a
      # second node to hit the same 1,000 sites again. Measured 2026-08-28:
      # 29 such requeues in 48h, ~29,000 domains crawled twice, and one of
      # those pairs became a Vultr abuse report (two visits to one homepage
      # from two of our IPs, 31 minutes apart). Politeness must hold across
      # the FLEET, not just within one node.
      {done, needed} = Enum.split_with(items, fn {_id, data, _ts} ->
        recently_crawled?(data[:ctl_domain] || data[:domain])
      end)

      if done != [] do
        Logger.info("⏱️  Requeue skipped #{length(done)} already-crawled domains")
      end

      Enum.each(needed, fn {_old_id, data, _old_ts} ->
        :ets.insert(@queue_table, {tail_key(data), data, now})
      end)

      count + length(needed)
    end)
  rescue
    _ -> 0
  end

  @doc false
  # Pure: is a batch past its in-flight timeout? `last_beat_ms` is the
  # dequeue time or the latest heartbeat, whichever is newer.
  @spec timed_out?(integer(), integer(), pos_integer()) :: boolean()
  def timed_out?(last_beat_ms, now_ms, timeout_ms \\ @batch_timeout_ms), do: now_ms - last_beat_ms >= timeout_ms

  @doc false
  # Record each completed result's domain so a late timeout cannot re-crawl it.
  def mark_recently_crawled(results) when is_list(results) do
    now = System.system_time(:millisecond)

    Enum.each(results, fn r ->
      case r[:domain] || r[:ctl_domain] do
        d when is_binary(d) and d != "" -> :ets.insert(@recent_table, {d, now})
        _ -> :ok
      end
    end)
  rescue
    ArgumentError -> :ok
  end

  def mark_recently_crawled(_), do: :ok

  @doc false
  def recently_crawled?(domain) when is_binary(domain) do
    case :ets.lookup(@recent_table, domain) do
      [{^domain, ts}] -> System.system_time(:millisecond) - ts < @recent_ttl_ms
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  def recently_crawled?(_), do: false

  @doc false
  # Drop expired entries, called from the existing TTL sweep. Logs what it
  # does: the earlier version discarded its own return value, so a sweep that
  # silently stopped working (a bad match spec, a crash swallowed by rescue)
  # would have looked identical to a healthy one in every log there is.
  def sweep_recently_crawled do
    cutoff = System.system_time(:millisecond) - @recent_ttl_ms
    expired = :ets.select_delete(@recent_table, [{{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}])

    over = :ets.info(@recent_table, :size) - @recent_max_entries
    trimmed = if is_integer(over) and over > 0, do: LS.Cache.evict_to(@recent_table, @recent_max_entries, {:"$2", :"$1"}), else: 0

    if expired + trimmed > 0 do
      Logger.info("🧹 recently_crawled: dropped #{expired} expired, trimmed #{trimmed} over cap")
    end

    expired + trimmed
  rescue
    ArgumentError -> 0
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_ttl, @cleanup_interval_ms)
  end

  defp schedule_inflight_check do
    Process.send_after(self(), :check_inflight, @inflight_check_ms)
  end
end
