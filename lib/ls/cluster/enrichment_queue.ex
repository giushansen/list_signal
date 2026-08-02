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
  # Browser-needing items (WAF-blocked / 401 / 403 / 429 at discovery) live in
  # their own bucket so RESIDENTIAL nodes (home IPs — what actually beats a
  # WAF) can ask for them first, while datacenter nodes prefer plain-HTTP
  # items. Neither class is exclusive: datacenter nodes also run camoufox and
  # take browser work whenever it piles up (or nothing else is queued), and
  # residential nodes top up with normal items — the affinity just steers each
  # item to the node class most likely to succeed at it.
  @table_browser :enrichment_queue_browser
  @inflight :enrichment_inflight
  @attempted :enrichment_attempted
  @target_depth 5_000
  # Of that depth, this much is reserved for WAF-walled work. The natural
  # arrival rate is ~12%, but the BACKLOG is ~900K blocked businesses against
  # ~30 renders/min of fleet capacity, so the browser lane is deliberately
  # over-fed until it clears: idle camoufox is paid-for capacity going to
  # waste, and blocked domains are often the brands worth the most.
  @browser_target_depth 1_500
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
    :ets.new(@table_browser, [:ordered_set, :public, :named_table])
    :ets.new(@inflight, [:set, :public, :named_table])
    :ets.new(@attempted, [:set, :public, :named_table])
    send(self(), :refill)
    Process.send_after(self(), :check_inflight, 60_000)
    Logger.info("🔬 EnrichmentQueue started (target depth: #{@target_depth})")
    {:ok, %{enqueued: 0, completed: 0, refills: 0}}
  end

  # Old agents (pre residential-affinity) send the 3-tuple: treat as datacenter.
  @impl true
  def handle_call({:dequeue_lane, :enrichment, count}, from, state),
    do: handle_call({:dequeue_lane, :enrichment, count, :datacenter}, from, state)

  @impl true
  def handle_call({:dequeue_lane, :enrichment, count, node_class}, _from, state) do
    case take_for(node_class, count) do
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
       queue_depth: :ets.info(@table, :size) + :ets.info(@table_browser, :size),
       browser_depth: :ets.info(@table_browser, :size),
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
    prune_attempted()

    # Two budgets, refilled independently. A single query cannot serve both:
    # blocked businesses have no emails and weak classification BECAUSE they
    # could not be crawled, so any value ordering buries them under millions
    # of reachable rows and the browser bucket starves at zero.
    browser_added =
      fill_bucket(
        @table_browser,
        max(@browser_target_depth - :ets.info(@table_browser, :size), 0),
        browser_only: true
      )

    normal_added =
      fill_bucket(
        @table,
        max(@target_depth - @browser_target_depth - :ets.info(@table, :size), 0),
        browser_only: false
      )

    added = browser_added + normal_added

    if added > 0 do
      Logger.info("[ENRICH] refilled #{added} domains (#{browser_added} browser, #{normal_added} http)")
    end

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
        Enum.each(items, &:ets.insert(bucket_for(&1), {:erlang.unique_integer([:monotonic, :positive]), &1}))
        length(items)
      end)
      |> Enum.sum()

    if requeued > 0, do: Logger.warning("[ENRICH] requeued #{requeued} stranded items")
    Process.send_after(self(), :check_inflight, 60_000)
    {:noreply, state}
  end

  defp fill_bucket(_table, 0, _opts), do: 0

  defp fill_bucket(table, missing, opts) do

    # Over-fetch 5x: the SQL LIMIT applies BEFORE the cooldown filter, so when
    # the frontier sits in a band of recently-attempted domains, fetching
    # exactly `missing` returns the same rejected slice every refill and the
    # bucket starves with millions of candidates below it.
    # Belt to the SQL's braces: never enqueue a domain already queued or in
    # flight — duplicates burn a full enrichment each.
    queued =
      MapSet.new(
        Enum.map(:ets.tab2list(@table) ++ :ets.tab2list(@table_browser), fn {_, item} -> item.domain end) ++
          Enum.flat_map(:ets.tab2list(@inflight), fn {_, items, _} ->
            Enum.map(items, & &1.domain)
          end)
      )

    case LS.Clickhouse.businesses_needing_enrichment(missing * 5, opts) do
      {:ok, rows} ->
        rows
        |> Enum.reject(&(recently_attempted?(&1.domain) or MapSet.member?(queued, &1.domain)))
        |> Enum.uniq_by(& &1.domain)
        |> Enum.take(missing)
        |> tap(fn fresh ->
          Enum.each(fresh, fn item ->
            :ets.insert(table, {:erlang.unique_integer([:monotonic, :positive]), item})
          end)
        end)
        |> length()

      _ ->
        0
    end
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

  # WAF-blocked / auth-walled at discovery = the browser bucket.
  defp bucket_for(item) do
    # 429 deliberately absent: a rate limit is not a wall a browser gets past,
    # it is a request to come back later. Sending those to the render path
    # made them 83% of all failures (2026-08-02) while consuming the scarcest
    # resource we have — and hammering a CDN that already said "slow down"
    # is exactly how source IPs get blacklisted.
    if item[:http_blocked] not in [nil, ""] or item[:last_http_status] in [401, 403],
      do: @table_browser,
      else: @table
  end

  @doc """
  How many of `count` items a node of this class takes from the browser bucket
  before touching the HTTP bucket. Public because the split is a contract: get
  it wrong and paid-for camoufox capacity silently idles.
  """
  @spec browser_share(:residential | :datacenter, pos_integer()) :: non_neg_integer()
  def browser_share(:residential, count), do: count
  def browser_share(_datacenter, count), do: div(count, 3)

  # Residential nodes drain the browser bucket first — home IPs are what beat
  # WAFs — then top up with normal items.
  defp take_for(:residential, count) do
    browser = take(@table_browser, browser_share(:residential, count))
    browser ++ take(@table, count - length(browser))
  end

  # Datacenter nodes take a FIXED SHARE of browser work, not "browser only if
  # the HTTP bucket happens to be empty". That ordering meant they never took
  # any: the HTTP bucket is never empty, so nine camoufox-equipped nodes sat
  # idle while one residential node carried the entire ~900K blocked backlog.
  # A third of each batch keeps every sidecar fed; residential still gets
  # first pick of the hardest work because it drains the same bucket first.
  defp take_for(_datacenter, count) do
    browser = take(@table_browser, browser_share(:datacenter, count))
    normal = take(@table, count - length(browser))
    # If either bucket ran dry, backfill from the other so a node never idles.
    short = count - length(browser) - length(normal)
    browser ++ normal ++ take(@table_browser, short)
  end

  defp take(_table, count) when count <= 0, do: []

  defp take(table, count) do
    Enum.reduce_while(1..count, [], fn _, acc ->
      case :ets.first(table) do
        :"$end_of_table" ->
          {:halt, acc}

        key ->
          case :ets.lookup(table, key) do
            [{^key, item}] -> :ets.delete(table, key); {:cont, [item | acc]}
            [] -> {:cont, acc}
          end
      end
    end)
  end
end
