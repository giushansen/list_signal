defmodule LS.Cluster.CrawlDedup do
  @moduledoc """
  Fleet-wide "did we crawl this in the last 7 days?" answered by eight
  rotating daily bloom filters, plus a record of every certificate sighting
  the gate suppressed. Master-only, consulted by `LS.Cluster.WorkQueue.enqueue/1`.

  ## Why (2026-09-04, tightened 2026-09-06)

  Measured over the 7 days before dedup shipped: 62.3M crawls for 45.1M
  distinct domains, so 17.2M fetches (27.6% of everything the fleet did)
  were repeat visits inside one week. A certificate renewal appears in many
  CT logs hours apart, and the CTL cache that was supposed to absorb that
  holds ~1 hour of inflow. Beyond the waste, repeat visits from rotating
  worker IPs are what turned two single-request crawls into Vultr abuse
  reports.

  The first version used two blooms rotated every 3.5 days, so a domain was
  suppressed for 3.5 to 7 days depending on where in the rotation it
  landed. The owner's rule is "a business is fetched at most once every 7
  days": eight daily windows make that exact. A domain crawled at time T is
  suppressed until the bloom it was written to rotates out, between 7 and 8
  days later, and the weekly recrawl tier (which selects domains 7+ days
  stale) bypasses the gate outright with `force: true` because it IS the
  schedule.

  ## What a suppressed sighting still records

  Suppressing the crawl must not throw away what the certificate said. Every
  suppressed CT entry is appended to `ctl_sightings` (issuer, subdomain
  count, subdomains, seen time), batched from an ETS buffer so the poller's
  hot path only pays an ETS insert. The store page and the export read
  subdomains from `businesses` and, for the last 90 days, from this table.
  It deliberately does NOT write to `domains_history`: `domains_current` is
  newest-row-wins on that table, so a row carrying only certificate columns
  would blank the domain's DNS and HTTP data.

  ## Failure modes, chosen deliberately

  - **Fails open.** No blooms in `:persistent_term` (worker node, test,
    boot race) means "not seen": a dedup outage must never stop discovery.
  - **False positives delay, never lose.** At 1% FP a new domain can be
    wrongly suppressed, but only until the bloom it hashed into rotates
    out; CT re-emits on the next cert event and the recrawl tiers sweep
    everything eventually.
  - **Restarts reopen the window briefly.** Blooms die with the BEAM, so
    init backfills the last `@backfill_days` days of crawled domains from
    ClickHouse, each day into the bloom of its age, in 16 hash shards
    (bounded queries, the master is memory-capped) in a background task.

  Sized for 10M entries per daily bloom at 1% FP (inflow is ~7M
  domains/day): ~12MB each, ~96MB for all eight, on a box whose BEAM steady
  state is ~2G under a 9G limit.
  """

  use GenServer
  require Logger

  alias LS.Reputation.Bloom

  @pt_key {__MODULE__, :blooms}
  @windows 8
  @rotate_ms :timer.hours(24)
  @capacity 10_000_000
  @fp_rate 0.01
  @backfill_shards 16
  @backfill_days 3
  @sightings :ctl_sightings_buffer
  @flush_ms 30_000
  @flush_rows 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  True if `domain` was crawled in the suppression window (skip it);
  otherwise records it and returns false (crawl it).

  Runs in the caller's process: reads are `:atomics` loads and the write is
  lock-free, so the CT poller's hot path never queues behind a GenServer.
  """
  @spec seen_or_mark(term()) :: boolean()
  def seen_or_mark(domain) when is_binary(domain) and domain != "" do
    case :persistent_term.get(@pt_key, nil) do
      [newest | _] = blooms ->
        if Enum.any?(blooms, &Bloom.member?(&1, domain)) do
          true
        else
          Bloom.put(newest, domain)
          false
        end

      _ ->
        false
    end
  end

  def seen_or_mark(_), do: false

  @doc """
  Remember what a suppressed certificate sighting said. Cheap: one ETS
  insert; the GenServer ships the buffer to ClickHouse in batches.
  """
  @spec record_sighting(map()) :: :ok
  def record_sighting(%{} = data) do
    domain = data[:ctl_domain] || data[:domain]

    # Bounded: with ClickHouse away the buffer stops growing at 4x the flush
    # size and newer sightings are dropped, so the poller's memory is never
    # hostage to a ClickHouse outage.
    if is_binary(domain) and domain != "" and :ets.info(@sightings) != :undefined and
         :ets.info(@sightings, :size) < @flush_rows * 4 do
      :ets.insert(@sightings, {:erlang.unique_integer([:monotonic]), sighting_row(domain, data)})
    end

    :ok
  rescue
    _ -> :ok
  end

  def record_sighting(_), do: :ok

  @doc false
  # Pure: the TabSeparated row for one sighting. Third-party strings (issuer,
  # subdomains) are hostile: tabs, newlines and backslashes would break the
  # whole batch, so they are stripped, and the subdomain list is capped.
  def sighting_row(domain, data) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

    [
      clean(domain, 253),
      now,
      clean(data[:ctl_tld] || "", 63),
      clean(data[:ctl_issuer] || "", 200),
      data[:ctl_subdomain_count] |> to_count(),
      clean(data[:ctl_subdomains] || "", 4_000)
    ]
    |> Enum.join("\t")
  end

  defp clean(v, max) when is_binary(v) do
    v |> String.replace(["\t", "\n", "\r", "\\"], " ") |> String.slice(0, max)
  end

  defp clean(v, max), do: clean(to_string(v), max)

  defp to_count(n) when is_integer(n) and n >= 0, do: min(n, 65_535)
  defp to_count(_), do: 0

  @doc "Entry counts and memory, for the admin dashboard."
  def stats do
    case :persistent_term.get(@pt_key, nil) do
      blooms when is_list(blooms) ->
        %{
          windows: length(blooms),
          entries: Enum.map(blooms, &Bloom.count/1),
          memory_mb: blooms |> Enum.map(&Bloom.memory_mb/1) |> Enum.sum() |> Float.round(1),
          sightings_buffered: (:ets.info(@sightings, :size) || 0)
        }

      _ ->
        %{windows: 0, entries: [], memory_mb: 0.0, sightings_buffered: 0}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@sightings, [:set, :public, :named_table, write_concurrency: true])
    :persistent_term.put(@pt_key, for(_ <- 1..@windows, do: Bloom.new(@capacity, @fp_rate)))
    Process.send_after(self(), :rotate, @rotate_ms)
    Process.send_after(self(), :flush, @flush_ms)
    send(self(), :backfill)

    Logger.info("🔁 CrawlDedup started (#{@windows} daily windows x #{@capacity} entries, suppression 7-8 days)")

    {:ok, %{recorded: 0}}
  end

  @impl true
  def handle_info(:rotate, state) do
    blooms = :persistent_term.get(@pt_key)
    {kept, [dropped]} = Enum.split(blooms, @windows - 1)
    :persistent_term.put(@pt_key, [Bloom.new(@capacity, @fp_rate) | kept])
    Process.send_after(self(), :rotate, @rotate_ms)
    Logger.info("🔁 CrawlDedup rotated (dropped a window of #{Bloom.count(dropped)} entries)")
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    n = flush_sightings()
    Process.send_after(self(), :flush, @flush_ms)
    {:noreply, %{state | recorded: state.recorded + n}}
  end

  # Refill the window after a restart so the watchdog cycling the master
  # does not reopen the duplicate-crawl gap every time. Sharded so no single
  # response is large on the memory-capped master; async so boot never waits.
  def handle_info(:backfill, state) do
    Task.start(fn -> backfill() end)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state) do
    flush_sightings()
    :ok
  end

  @doc false
  def flush_sightings do
    if :ets.info(@sightings) == :undefined do
      0
    else
      rows = :ets.tab2list(@sightings)
      # Only what was read is deleted: rows inserted meanwhile survive.
      Enum.each(rows, fn {id, _} -> :ets.delete(@sightings, id) end)

      case rows do
        [] ->
          0

        _ ->
          tsv = Enum.map_join(rows, "\n", fn {_, row} -> row end)

          case LS.Clickhouse.insert_raw(
                 "INSERT INTO ctl_sightings (domain, seen_at, ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains) FORMAT TabSeparated",
                 tsv
               ) do
            :ok ->
              length(rows)

            {:error, reason} ->
              Logger.warning("🔁 CrawlDedup: #{length(rows)} sightings lost (#{inspect(reason)})")
              0
          end
      end
    end
  rescue
    _ -> 0
  end

  @doc false
  def buffer_cap, do: @flush_rows * 4

  defp backfill do
    blooms = :persistent_term.get(@pt_key)

    total =
      for age <- 0..(@backfill_days - 1), shard <- 0..(@backfill_shards - 1), reduce: 0 do
        acc ->
          bloom = Enum.at(blooms, age)

          sql =
            "SELECT DISTINCT domain FROM domains_history " <>
              "WHERE enriched_at >= now() - INTERVAL #{age + 1} DAY AND enriched_at < now() - INTERVAL #{age} DAY " <>
              "AND cityHash64(domain) % #{@backfill_shards} = #{shard}"

          case LS.Clickhouse.query_raw(sql, 60_000, background: true) do
            {:ok, rows} ->
              Enum.each(rows, fn [d] -> Bloom.put(bloom, d) end)
              acc + length(rows)

            _ ->
              acc
          end
      end

    Logger.info("🔁 CrawlDedup backfilled #{total} domains from the last #{@backfill_days} days")
  rescue
    e -> Logger.warning("CrawlDedup backfill failed (dedup starts cold): #{Exception.message(e)}")
  end
end
