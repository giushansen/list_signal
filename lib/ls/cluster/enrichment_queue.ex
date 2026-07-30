defmodule LS.Cluster.EnrichmentQueue do
  @moduledoc """
  Work queue for the **enrichment lane** (pipeline 2). Master-only.

  Deliberately separate from `LS.Cluster.WorkQueue` rather than a lane inside
  it: discovery runs at thousands of items/minute with disposable items, while
  enrichment runs at tens/minute with items that cost ~40s of browser time.
  Mixing them would mean one set of tuning constants serving two very
  different workloads, and any bug here would put discovery at risk.

  **Durability by refill, not by disk.** The queue is in-memory, but every item
  is derived from a ClickHouse query ("businesses whose depth data is stale"),
  so a master restart loses nothing that a refill cannot reconstruct. That is
  simpler and less fragile than a write-ahead queue on disk.

  Refill cadence is `@refill_interval_ms`; the queue tops up to
  `@target_depth` and never grows beyond it, so enrichment can never starve
  the box the way an unbounded queue could.
  """

  use GenServer
  require Logger

  @table :enrichment_queue
  @inflight :enrichment_inflight
  @attempted :enrichment_attempted
  @target_depth 5_000
  @refill_interval_ms 300_000
  @batch_timeout_ms 900_000
  # A domain whose enrichment crashes or exceeds the agent's 120s task timeout
  # produces NO biz_enrichment row, so the refill query re-selects it forever:
  # on 2026-07-29 the queue reached a tranco band dense with WAF/dead domains
  # and spent the whole night re-attempting the same ones (~1,200 dequeued/h,
  # ~50 written/h). Remembering attempts in memory caps that to one try per
  # domain per day. Deliberately NOT a "failed" marker row in biz_enrichment —
  # a newer empty row would supersede a good one at merge time (ReplacingMergeTree),
  # which is exactly the blanking the pipeline design forbids.
  @attempt_cooldown_ms 24 * 3_600_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queue depth, in-flight batches and lifetime totals."
  @spec stats() :: map()
  def stats, do: GenServer.call(__MODULE__, :stats)

  @doc "Force an immediate refill from ClickHouse (normally every 5 min)."
  def refill_now, do: send(__MODULE__, :refill) && :ok

  @impl true
  def init(_opts) do
    :ets.new(@table, [:ordered_set, :public, :named_table])
    :ets.new(@inflight, [:set, :public, :named_table])
    :ets.new(@attempted, [:set, :public, :named_table])
    send(self(), :refill)
    Process.send_after(self(), :check_inflight, 60_000)
    Logger.info("🔬 EnrichmentQueue started (target depth: #{@target_depth})")
    {:ok, %{enqueued: 0, completed: 0, refills: 0}}
  end

  @impl true
  def handle_call({:dequeue_lane, :enrichment, count}, _from, state) do
    case take(count) do
      [] ->
        {:reply, :empty, state}

      items ->
        batch_id = :erlang.unique_integer([:monotonic, :positive])
        now = System.system_time(:millisecond)
        :ets.insert(@inflight, {batch_id, items, now})
        Enum.each(items, &:ets.insert(@attempted, {&1.domain, now}))
        {:reply, {:ok, batch_id, items}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     Map.merge(state, %{
       queue_depth: :ets.info(@table, :size),
       inflight_batches: :ets.info(@inflight, :size)
     }), state}
  end

  @impl true
  def handle_cast({:complete_enrichment, batch_id, results}, state) do
    :ets.delete(@inflight, batch_id)
    LS.Cluster.EnrichmentWriter.write(results)
    {:noreply, %{state | completed: state.completed + length(results)}}
  end

  @impl true
  def handle_info(:refill, state) do
    missing = max(@target_depth - :ets.info(@table, :size), 0)

    prune_attempted()

    added =
      if missing > 0 do
        # Over-fetch 5x: the SQL LIMIT applies BEFORE the cooldown filter, so
        # when the tranco-frontier sits in a band of recently-attempted
        # domains, fetching exactly `missing` returns the same rejected slice
        # every refill and the queue starves with millions of candidates
        # below. Five times the ask rides past a full cooled-down band.
        case LS.Clickhouse.businesses_needing_enrichment(missing * 5) do
          {:ok, rows} ->
            rows
            |> Enum.reject(&recently_attempted?(&1.domain))
            |> Enum.take(missing)
            |> tap(fn fresh ->
              Enum.each(fresh, fn item ->
                :ets.insert(@table, {:erlang.unique_integer([:monotonic, :positive]), item})
              end)
            end)
            |> length()

          _ ->
            0
        end
      else
        0
      end

    if added > 0, do: Logger.info("[ENRICH] refilled #{added} domains")
    Process.send_after(self(), :refill, @refill_interval_ms)
    {:noreply, %{state | enqueued: state.enqueued + added, refills: state.refills + 1}}
  end

  @impl true
  def handle_info(:check_inflight, state) do
    cutoff = System.system_time(:millisecond) - @batch_timeout_ms

    requeued =
      :ets.tab2list(@inflight)
      |> Enum.filter(fn {_id, _items, started} -> started < cutoff end)
      |> Enum.map(fn {id, items, _} ->
        :ets.delete(@inflight, id)
        Enum.each(items, &:ets.insert(@table, {:erlang.unique_integer([:monotonic, :positive]), &1}))
        length(items)
      end)
      |> Enum.sum()

    if requeued > 0, do: Logger.warning("[ENRICH] requeued #{requeued} stranded items")
    Process.send_after(self(), :check_inflight, 60_000)
    {:noreply, state}
  end

  defp recently_attempted?(domain) do
    case :ets.lookup(@attempted, domain) do
      [{_, ts}] -> System.system_time(:millisecond) - ts < @attempt_cooldown_ms
      [] -> false
    end
  end

  defp prune_attempted do
    cutoff = System.system_time(:millisecond) - @attempt_cooldown_ms
    :ets.select_delete(@attempted, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp take(count) do
    Enum.reduce_while(1..count, [], fn _, acc ->
      case :ets.first(@table) do
        :"$end_of_table" ->
          {:halt, acc}

        key ->
          case :ets.lookup(@table, key) do
            [{^key, item}] -> :ets.delete(@table, key); {:cont, [item | acc]}
            [] -> {:cont, acc}
          end
      end
    end)
  end
end
