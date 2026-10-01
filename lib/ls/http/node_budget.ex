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
  """

  @table :http_node_budget
  @default_per_min 140
  # A reservation further out than this means the node is overloaded. The
  # line is as long as the batch's HTTP candidates at one slot each: 350
  # candidates at 140/min is 150 s, and the HTTP stage await is sized for
  # it (LS.Cluster.WorkerAgent.http_stage_timeout/2). A 45 s cap refused
  # 19% of fetches in the first paced hour (2026-10-02); five minutes
  # covers the largest batch and still refuses a runaway line.
  @max_wait_ms 300_000

  @doc "Create the counter table. Idempotent."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
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
  Reserve the next fetch slot. `:ok` to fetch now; `{:wait, ms}` with a
  slot held for the caller that many milliseconds from now; `:overloaded`
  when the next free slot is more than #{@max_wait_ms} ms away.

  Slots are spaced evenly (60,000 / per_min ms apart), so the rate is
  smooth within the minute instead of 100 concurrent tasks spending the
  budget in the first seconds and the rest of the minute waiting. The
  first version did exactly that (2026-10-01 evening): 12.9% of fetches
  gave up as rate_limited and one-minute peaks still reached 275.
  """
  @spec take(pos_integer()) :: :ok | {:wait, pos_integer()} | :overloaded
  def take(limit \\ per_min()) do
    init()
    interval = div(60_000, limit)
    now = System.monotonic_time(:millisecond)
    # Atomic reservation: advance the shared "next free slot" by one interval
    # and read what it was before. Behind `now` means the slot is free now.
    # update_counter returns the advanced value; the slot we hold is the one before it.
    base = :ets.update_counter(@table, :next_at, {2, interval}, {:next_at, now}) - interval
    cond do
      base <= now ->
        # The line went idle: pull the next slot forward so idle time is
        # not banked as a burst (counter already advanced from `base`).
        if now - base > interval, do: :ets.insert(@table, {:next_at, now + interval})
        :ok

      base - now > @max_wait_ms ->
        :ets.update_counter(@table, :next_at, {2, -interval})
        :overloaded

      true ->
        {:wait, base - now}
    end
  end

  @doc "Milliseconds until the next free slot, for stats (0 when idle)."
  def backlog_ms do
    init()

    case :ets.lookup(@table, :next_at) do
      [{_, t}] -> max(t - System.monotonic_time(:millisecond), 0)
      [] -> 0
    end
  end
end
