defmodule LS.Cluster.CrawlDedup do
  @moduledoc """
  Fleet-wide "did we crawl this recently?" answered by two rotating bloom
  filters. Master-only, consulted by `LS.Cluster.WorkQueue.enqueue/1`.

  ## Why (2026-09-04)

  Measured over the 7 days before this shipped: 62.3M crawls for 45.1M
  distinct domains, so 17.2M fetches (27.6% of everything the fleet did)
  were repeat visits inside one week. The worst domains were hit 20+
  times, and they were ordinary small sites, not platforms: a certificate
  renewal appears in many CT logs hours apart, and the CTL cache that was
  supposed to absorb that holds ~1 hour of inflow at 1,400 domains/s.
  Beyond the waste, repeat visits from rotating worker IPs are what turned
  two single-request crawls into Vultr abuse reports.

  ## How the window works

  Two blooms, `current` and `previous`, rotated every 3.5 days. An
  enqueued domain is written to `current` and suppressed while it is in
  either bloom, so suppression lasts between 3.5 and 7 days depending on
  where in the rotation it landed. The floor matters more than the
  ceiling: nothing gets crawled twice within 3.5 days, and the weekly
  recrawl tier (which selects domains 7+ days stale) always passes because
  every entry is gone by day 7.

  ## Failure modes, chosen deliberately

  - **Fails open.** No blooms in `:persistent_term` (worker node, test,
    boot race) means "not seen": a dedup outage must never stop discovery.
  - **False positives delay, never lose.** At 1% FP a new domain can be
    wrongly suppressed, but only until the bloom it hashed into rotates
    out (at most 7 days); CT re-emits on the next cert event and the
    recrawl tiers sweep everything eventually.
  - **Restarts reopen the window briefly.** Blooms die with the BEAM, so
    init backfills the last 24h of crawled domains from ClickHouse in
    16 hash shards (bounded queries, the master is memory-capped) in a
    background task. The 24h slice covers the dominant same-day
    duplicates; the 3.5-day tail rebuilds itself as traffic flows.

  Sized for 50M entries per bloom at 1% FP: ~57MB each, ~114MB both, on a
  box whose BEAM steady state is ~4G under a 9G limit.
  """

  use GenServer
  require Logger

  alias LS.Reputation.Bloom

  @pt_key {__MODULE__, :blooms}
  @rotate_ms round(:timer.hours(24) * 3.5)
  @capacity 50_000_000
  @fp_rate 0.01
  @backfill_shards 16
  @backfill_hours 24

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  True if `domain` was enqueued in the suppression window (skip it);
  otherwise records it and returns false (crawl it).

  Runs in the caller's process: reads are `:atomics` loads and the write is
  lock-free, so the CT poller's hot path never queues behind a GenServer.
  """
  @spec seen_or_mark(term()) :: boolean()
  def seen_or_mark(domain) when is_binary(domain) and domain != "" do
    case :persistent_term.get(@pt_key, nil) do
      {current, previous} ->
        if Bloom.member?(current, domain) or Bloom.member?(previous, domain) do
          true
        else
          Bloom.put(current, domain)
          false
        end

      nil ->
        false
    end
  end

  def seen_or_mark(_), do: false

  @doc "Entry counts and memory, for the admin dashboard."
  def stats do
    case :persistent_term.get(@pt_key, nil) do
      {current, previous} ->
        %{
          current_entries: Bloom.count(current),
          previous_entries: Bloom.count(previous),
          memory_mb: Bloom.memory_mb(current) + Bloom.memory_mb(previous)
        }

      nil ->
        %{current_entries: 0, previous_entries: 0, memory_mb: 0.0}
    end
  end

  @impl true
  def init(_opts) do
    :persistent_term.put(@pt_key, {Bloom.new(@capacity, @fp_rate), Bloom.new(@capacity, @fp_rate)})
    Process.send_after(self(), :rotate, @rotate_ms)
    send(self(), :backfill)

    Logger.info(
      "🔁 CrawlDedup started (2x #{@capacity} entries, rotate #{Float.round(@rotate_ms / 86_400_000, 1)}d)"
    )

    {:ok, %{}}
  end

  @impl true
  def handle_info(:rotate, state) do
    {current, _dropped} = :persistent_term.get(@pt_key)
    :persistent_term.put(@pt_key, {Bloom.new(@capacity, @fp_rate), current})
    Process.send_after(self(), :rotate, @rotate_ms)
    Logger.info("🔁 CrawlDedup rotated (#{Bloom.count(current)} entries moved to previous)")
    {:noreply, state}
  end

  # Refill the window after a restart so the watchdog cycling the master
  # does not reopen the duplicate-crawl gap every time. Sharded so no single
  # response is large on the memory-capped master; async so boot never waits.
  def handle_info(:backfill, state) do
    Task.start(fn -> backfill() end)
    {:noreply, state}
  end

  defp backfill do
    {current, _} = :persistent_term.get(@pt_key)

    total =
      Enum.reduce(0..(@backfill_shards - 1), 0, fn shard, acc ->
        sql =
          "SELECT DISTINCT domain FROM domains_history " <>
            "WHERE enriched_at >= now() - INTERVAL #{@backfill_hours} HOUR " <>
            "AND cityHash64(domain) % #{@backfill_shards} = #{shard}"

        case LS.Clickhouse.query_raw(sql, 60_000, background: true) do
          {:ok, rows} ->
            Enum.each(rows, fn [d] -> Bloom.put(current, d) end)
            acc + length(rows)

          _ ->
            acc
        end
      end)

    Logger.info("🔁 CrawlDedup backfilled #{total} domains from the last #{@backfill_hours}h")
  rescue
    e -> Logger.warning("CrawlDedup backfill failed (dedup starts cold): #{Exception.message(e)}")
  end
end
