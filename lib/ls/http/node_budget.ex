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
  Take one unit of this minute's budget. `:ok` to fetch now, or
  `{:wait, ms}` until the next minute starts.
  """
  @spec take(pos_integer()) :: :ok | {:wait, pos_integer()}
  def take(limit \\ per_min()) do
    init()
    now_ms = System.system_time(:millisecond)
    minute = div(now_ms, 60_000)
    n = :ets.update_counter(@table, minute, {2, 1}, {minute, 0})

    if n <= limit do
      if n == 1, do: :ets.select_delete(@table, [{{:"$1", :_}, [{:<, :"$1", minute - 1}], [true]}])
      :ok
    else
      {:wait, max((minute + 1) * 60_000 - now_ms, 1)}
    end
  end

  @doc "Fetches taken in the current minute, for stats."
  def used_this_minute do
    init()

    case :ets.lookup(@table, div(System.system_time(:millisecond), 60_000)) do
      [{_, n}] -> n
      [] -> 0
    end
  end
end
