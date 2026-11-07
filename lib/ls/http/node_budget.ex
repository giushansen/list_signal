defmodule LS.HTTP.NodeBudget do
  @moduledoc """
  A per-node ceiling on outbound fetches per minute, on top of the per-IP
  spacing in `LS.HTTP.IPRateLimiter`.

  Why (2026-10-01): the per-IP limiter protects each destination; nothing
  protected our own source address. The measured safe envelope for one
  source IP is 130 to 160 fetches a minute (`docs/crawl-capacity.md`:
  sub-1% 429s, zero blocks). Before the crawl-gate change a worker made
  about 52 attempts a minute; with filtered domains no longer filling
  batches and the commerce-edge and mail-provider inventory crawling, the
  fleet averaged 119 a minute per worker with one-minute bursts of 355.
  Abuse reports come from bursts, not averages, so the budget is a hard
  cap per wall-clock minute: a fetch that would exceed it waits for the
  next minute. The crawl gets slower on that node, never ruder.

  `LS_FETCH_PER_MIN` overrides the default (140). The owner's rule stands:
  capacity comes from more source IPs, never more rate per IP.

  Two lanes, one ceiling (2026-10-03). On a node that runs discovery and
  depth enrichment, both lanes fetched from the same line. The day the
  budget became airtight (the idle-claim fix), two discovery batches kept
  the line full, each depth fetch queued behind a minute of discovery
  slots, and a domain with four pages to visit blew its 120 s task
  timeout: ny1 and chi1 dropped 108 of 120 and 101 of 112 depth domains
  in one hour, and the fleet wrote 1,200 depth rows an hour against 5,300
  the day before. The enrichment lane now holds a reserved share of the
  ceiling (`LS_ENRICH_FETCH_PER_MIN`, default 30) on its own line; the
  discovery lane gets the rest. The two shares add up to the ceiling, so
  the source IP never sends more than before.

  The reserve is lent out while it is idle (2026-11-03). Measured on the
  duals that day: the enrichment line's backlog read 0 on every sample of
  chi1, par1, dal1 and ny1 while the discovery line was booked 60 to 127 s
  ahead, and the depth lane fetched 107 pages a minute across the whole
  fleet against 270 a minute reserved on the nine duals. A quarter of each
  dual's ceiling was idle by construction. Now `take/2` for discovery runs
  at the whole ceiling while the enrichment line has been quiet for
  `@borrow_after_ms`, and drops back to its share the moment the depth
  lane takes a slot again; the depth lane keeps its own line and its
  priority. In the minute the depth lane wakes, slots discovery already
  reserved at the full rate still fire, so that minute can reach ceiling
  plus reserve (150 at 120 and 30), inside the measured 130 to 160
  envelope. Redirect hops count too (`LS.HTTP.Client`): until this change
  a same-host hop took no slot and the node sent 157 requests a minute
  against a 120 budget (ny1, PerformanceTracker, 95 h).
  """

  @table :http_node_budget
  @default_per_min 140
  # A reservation further out than this means the node is overloaded. The
  # line is as long as the batch's HTTP candidates at one slot each: 350
  # candidates at 140/min is 150 s, and the HTTP stage await is sized for
  # it (LS.Cluster.WorkerAgent.http_stage_timeout/2). A 45 s cap refused
  # 19% of fetches in the first paced hour (2026-10-02) and a 300 s cap still
  # 10%: a batch can carry 700 candidates (300 s). Seven minutes covers it
  # and still refuses a runaway line; the batch in-flight limit is ten.
  @max_wait_ms 420_000
  @default_enrich_per_min 30
  # The enrichment line counts as idle, and its share as lendable, once its
  # next free slot is this far in the past.
  @borrow_after_ms 60_000

  @doc """
  Create the counter table. Idempotent. The table is owned by a process
  that lives as long as the node, not by the caller: until 2026-10-03 the
  first fetch task to call this owned it, and an ETS table dies with its
  owner, so every batch end deleted the line and the next batch started
  from an idle one.
  """
  def init do
    if :ets.whereis(@table) == :undefined do
      parent = self()

      spawn(fn ->
        try do
          :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
          send(parent, {:node_budget_table, :created})
          Process.sleep(:infinity)
        rescue
          ArgumentError -> send(parent, {:node_budget_table, :exists})
        end
      end)

      receive do
        {:node_budget_table, _} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  @doc "The ceiling in fetches per minute."
  @spec per_min() :: pos_integer()
  def per_min do
    case System.get_env("LS_FETCH_PER_MIN") do
      nil -> @default_per_min
      v -> (case Integer.parse(v) do {n, _} when n > 0 -> n; _ -> @default_per_min end)
    end
  end

  @doc """
  The share of the ceiling each lane may use on this node, from `LS_LANES`.

  Discovery alone: the whole ceiling. Enrichment alone (the NUC): the
  whole ceiling. Both: enrichment keeps `LS_ENRICH_FETCH_PER_MIN` (default
  #{@default_enrich_per_min}) and discovery the rest, never under one.
  """
  @spec lane_limit(:discovery | :enrichment) :: pos_integer()
  def lane_limit(lane) do
    lanes = LS.Application.worker_lanes()
    both? = "discovery" in lanes and "enrichment" in lanes
    reserve = min(enrich_per_min(), max(per_min() - 1, 1))

    case {lane, both?} do
      {:enrichment, true} -> reserve
      {:discovery, true} -> per_min() - reserve
      _ -> per_min()
    end
  end

  @doc false
  def enrich_per_min do
    case System.get_env("LS_ENRICH_FETCH_PER_MIN") do
      nil -> @default_enrich_per_min
      v -> (case Integer.parse(v) do {n, _} when n > 0 -> n; _ -> @default_enrich_per_min end)
    end
  end

  @doc """
  Reserve the next fetch slot on a lane's line. `:ok` to fetch now;
  `{:wait, ms}` with a slot held for the caller that many milliseconds
  from now; `:overloaded` when the next free slot is more than
  #{@max_wait_ms} ms away. `take/1` is the discovery line.

  Slots are spaced evenly (60,000 / per_min ms apart), so the rate is
  smooth within the minute instead of 100 concurrent tasks spending the
  budget in the first seconds and the rest of the minute waiting. The
  first version did exactly that (2026-10-01 evening): 12.9% of fetches
  gave up as rate_limited and one-minute peaks still reached 275.
  """
  @spec take(pos_integer(), :discovery | :enrichment) :: :ok | {:wait, pos_integer()} | :overloaded
  def take(limit \\ per_min(), lane \\ :discovery) do
    init()
    interval = div(60_000, effective_limit(limit, lane))
    now = System.monotonic_time(:millisecond)
    key = line_key(lane)

    # An idle line (next slot already in the past) is claimed by exactly ONE
    # caller, atomically, and moved to now + interval; everyone else lines
    # up behind it. The previous version let every concurrent caller that
    # found the line idle through at once and reset it afterwards, so an
    # idle gap of 30 s at 500 ms a slot admitted a burst of 60 fetches, and
    # with two batches alternating DNS and HTTP phases those gaps came every
    # few minutes: measured 2026-10-03 at 136 fetches a minute per node on
    # average, 186 on dal1, against a 120 ceiling. Bursts are what abuse
    # reports are made of.
    claimed =
      # `{:const, key}`: a tuple key written bare in a match-spec body reads
      # as a call, so the enrichment line's key must be passed as a constant.
      :ets.select_replace(@table, [{{key, :"$1"}, [{:<, :"$1", now}], [{{{:const, key}, now + interval}}]}])

    cond do
      claimed == 1 ->
        :ok

      :ets.insert_new(@table, {key, now + interval}) ->
        :ok

      true ->
        # update_counter returns the advanced value; the slot we hold is the
        # one before it, and it is never behind `now` by more than a tick.
        base = :ets.update_counter(@table, key, {2, interval}) - interval

        cond do
          base <= now -> :ok
          base - now > @max_wait_ms ->
            :ets.update_counter(@table, key, {2, -interval})
            :overloaded
          true -> {:wait, base - now}
        end
    end
  end

  @doc """
  The rate a lane's take runs at. Discovery borrows the enrichment reserve
  while that line is idle, never past the ceiling; enrichment always runs
  at what it asked for.
  """
  @spec effective_limit(pos_integer(), :discovery | :enrichment) :: pos_integer()
  def effective_limit(limit, :discovery) do
    if enrichment_idle?(), do: limit |> Kernel.+(reserve_share()) |> min(per_min()) |> max(limit), else: limit
  end

  def effective_limit(limit, _lane), do: limit

  @doc "Whether the enrichment line has taken no slot for #{@borrow_after_ms} ms."
  @spec enrichment_idle?() :: boolean()
  def enrichment_idle? do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, line_key(:enrichment)) do
      [{_, next_at}] -> next_at < now - @borrow_after_ms
      [] -> true
    end
  rescue
    ArgumentError -> true
  end

  @doc """
  Pure: the line a request of the batch's Shopify lane books
  (`LS.Cluster.WorkerAgent.fetch_split/6`): the shorter of the node's two
  lines, the depth line on a tie, the discovery line on a node that runs
  one lane.

  Measured on par1, 2026-11-07 03:47 UTC, one sample a second for two
  minutes: the depth line was booked 13.5 s ahead at the median, 15.5 s
  at p90 and never free, held by the three batches' Shopify lanes and
  about four depth-lane tasks at 2 s a slot, while the discovery line
  was free in 47 of 120 samples and Shopify's own 2 s line was idle in
  all 120. A store of three requests waited about 40 s for budget slots,
  so a lane one store wide finished about eight stores in its window and
  85,000 Shopify stores waited in the master's queue. Each line still
  fires at its own rate, so the node never sends more than its ceiling;
  a Shopify request just stops queueing for a slot behind depth pages
  while a discovery slot goes unused. The depth lane itself keeps its own
  line.

  On a node that runs one lane `lane_limit/1` gives every line the whole
  ceiling, so a request there must stay on the discovery line or the
  node would run two full lines at once.
  """
  @spec edge_line(boolean(), non_neg_integer(), non_neg_integer()) :: :discovery | :enrichment
  def edge_line(both_lanes?, enrichment_ms, discovery_ms)
  def edge_line(false, _enrichment_ms, _discovery_ms), do: :discovery
  def edge_line(true, enrichment_ms, discovery_ms) when is_integer(discovery_ms) and is_integer(enrichment_ms) and discovery_ms < enrichment_ms, do: :discovery
  def edge_line(true, _enrichment_ms, _discovery_ms), do: :enrichment

  @doc "The line the batch's Shopify lane books now (`edge_line/3` on this node's lines)."
  @spec edge_line() :: :discovery | :enrichment
  def edge_line, do: edge_line(reserve_share() > 0, backlog_ms(:enrichment), backlog_ms(:discovery))

  # The reserve a dual node holds for the depth lane; nothing on a node
  # that runs one lane, where the lane already has the whole ceiling.
  defp reserve_share do
    lanes = LS.Application.worker_lanes()
    if "discovery" in lanes and "enrichment" in lanes, do: min(enrich_per_min(), max(per_min() - 1, 1)), else: 0
  end

  @doc """
  Give back a slot the caller took and will not use (2026-11-03: the
  target's key was booked too far ahead after the node slot was taken).
  The line moves back one interval, so the next taker fires one slot
  earlier; the line is never moved into the past, so the worst case is the
  next taker firing at once.
  """
  @spec release(pos_integer(), :discovery | :enrichment) :: :ok
  def release(limit \\ per_min(), lane \\ :discovery) do
    init()
    interval = div(60_000, effective_limit(limit, lane))
    now = System.monotonic_time(:millisecond)
    key = line_key(lane)
    # Only a line still ahead of now is moved back, and never behind now.
    :ets.select_replace(@table, [
      {{key, :"$1"}, [{:>, :"$1", now + interval}], [{{{:const, key}, {:-, :"$1", interval}}}]},
      {{key, :"$1"}, [{:>, :"$1", now}], [{{{:const, key}, now}}]}
    ])
    count(:released)
    :ok
  end

  @doc "Count a paced request a stage did not plan for (a redirect hop, a 304)."
  @spec count(atom()) :: :ok
  def count(what) when is_atom(what) do
    init()
    :ets.update_counter(@table, {:count, what}, {2, 1}, {{:count, what}, 0})
    :ok
  end

  @doc "The counters kept by `count/1`, as a map."
  @spec counts() :: map()
  def counts do
    init()
    for {{:count, what}, n} <- :ets.tab2list(@table), into: %{}, do: {what, n}
  end

  # The discovery line keeps the historical key so its stats and tests read
  # as before; the enrichment line is a second key in the same table.
  defp line_key(:discovery), do: :next_at
  defp line_key(:enrichment), do: {:next_at, :enrichment}

  @doc "Milliseconds until a lane's next free slot, for stats (0 when idle)."
  def backlog_ms(lane \\ :discovery) do
    init()

    case :ets.lookup(@table, line_key(lane)) do
      [{_, t}] -> max(t - System.monotonic_time(:millisecond), 0)
      [] -> 0
    end
  end
end
