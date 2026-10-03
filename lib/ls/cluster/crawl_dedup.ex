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

  ## The stable ring: change-aware revisits (2026-09-09)

  Measured on prod (2% of domains, 45 days): 73.9% of all crawls in a week
  are revisits of domains first seen more than a week earlier, and 88.9% of
  revisits at least 7 days apart come back with the same title,
  technologies, apps and status. Two thirds of the fleet's fetches were
  confirming that nothing had changed.

  After each compaction pass the compactor asks ClickHouse which touched
  domains came back unchanged (`LS.Clickhouse.stable_domains/2`, top-100K
  domains excluded) and hands them to `mark_stable/1`, which writes them
  into a second ring of five WEEKLY blooms. `stable?/1` is checked by
  `LS.Cluster.WorkQueue.enqueue/2` before anything else, and unlike the
  daily ring it is NOT bypassed by `force: true`: the recrawl scheduler is
  the 7-day schedule, and a stable domain's schedule is 28-35 days. A
  suppressed sighting is still recorded. The first crawl after the ring
  releases a domain decides again: unchanged, it is marked for another
  four weeks; changed, it falls back to the weekly cadence.

  The ring is written to `LS.State.dir/0` every six hours and on shutdown
  and read back at boot (rotating as many weeks as passed), because a
  master restart that forgot it would refetch every stable domain in the
  fleet within a week. 20M entries per weekly bloom at 0.1% FP: ~36MB each,
  ~180MB for five. `LS_STABLE_REVISIT=false` turns the gate off without a
  deploy.
  """

  use GenServer
  require Logger

  alias LS.Reputation.Bloom

  @pt_key {__MODULE__, :blooms}
  @windows 8
  @rotate_ms :timer.hours(24)
  @capacity 10_000_000
  @fp_rate 0.01
  @stable_save_ms :timer.hours(6)

  # Three more rings share the stable ring's mechanics (2026-10-01, cost
  # and quality pass). Each is a list of blooms rotated on a fixed period;
  # a domain is a member for between (windows - 1) and windows periods.
  #
  #   :stable   unchanged on its last crawl        5 weekly windows, 28-35 days
  #   :dormant  twice unchanged, or a verdict that  3 monthly windows, 60-90 days
  #             DNS alone settles (low-value TLD,
  #             junk name, registry)
  #   :hot      a change was just recorded          4 weekly windows, 21-28 days;
  #             bypasses :stable and :dormant so a
  #             moving business is back on 7 days
  #
  # Sizing is measured: the first v2 morning wrote 1.36M distinct filtered
  # domains in eleven hours, almost all re-sightings of domains already
  # known, so a 40M monthly window holds the steady state with room; 2% false
  # positives on a dormant check costs one skipped recrawl of a domain that
  # already waits 60 days. Memory is allocated up front: 3 x 41 MB for
  # dormant, 4 x 6 MB for hot, next to the stable ring's 5 x 36 MB.
  @rings %{
    stable: %{key: {__MODULE__, :stable}, windows: 5, period_s: 7 * 86_400, capacity: 20_000_000, fp: 0.001, file: "stable_blooms.bin", counter: {__MODULE__, :stable_marked}},
    dormant: %{key: {__MODULE__, :dormant}, windows: 3, period_s: 30 * 86_400, capacity: 40_000_000, fp: 0.02, file: "dormant_blooms.bin", counter: {__MODULE__, :dormant_marked}},
    hot: %{key: {__MODULE__, :hot}, windows: 4, period_s: 7 * 86_400, capacity: 5_000_000, fp: 0.01, file: "hot_blooms.bin", counter: {__MODULE__, :hot_marked}},
    # Refresh tiers (2026-10-03, LS.Crawl.Tiers): the compactor marks every
    # compiled business of tier B or C here, so a certificate re-sighting
    # of a known business waits its tier's cadence instead of 7 days. Tier
    # A is governed by the daily ring and the stable ring alone. Bypassed by
    # `force: true` (the scheduler IS the tier schedule) and by :hot.
    # 7 windows of 10 days: a member for 60-70 days; 7 of 20: 120-140.
    # Capacity 8M per window at 1% is ~10 MB each, ~134 MB for both rings.
    tier_b: %{key: {__MODULE__, :tier_b}, windows: 7, period_s: 10 * 86_400, capacity: 8_000_000, fp: 0.01, file: "tier_b_blooms.bin", counter: {__MODULE__, :tier_b_marked}},
    tier_c: %{key: {__MODULE__, :tier_c}, windows: 7, period_s: 20 * 86_400, capacity: 8_000_000, fp: 0.01, file: "tier_c_blooms.bin", counter: {__MODULE__, :tier_c_marked}}
  }
  @ring_names Map.keys(@rings)
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
  True if `domain` was marked stable within the last 28-35 days, so the
  crawl is skipped even when the caller forces past the daily ring.
  Fails open like the daily ring, and is off under `LS_STABLE_REVISIT=false`.
  """
  @spec stable?(term()) :: boolean()
  def stable?(domain), do: Application.get_env(:ls, :stable_revisit, true) and in_ring?(:stable, domain)

  @doc "Remember that these domains came back unchanged. Returns how many were written."
  @spec mark_stable([String.t()]) :: non_neg_integer()
  def mark_stable(domains), do: mark(:stable, domains)

  @doc """
  True if `domain` is dormant: twice unchanged, or filtered on a verdict
  that only DNS or the name decides. Waits 60-90 days, whoever asks. Off
  under `LS_DORMANT_RING=false`.
  """
  @spec dormant?(term()) :: boolean()
  def dormant?(domain), do: Application.get_env(:ls, :dormant_ring, true) and in_ring?(:dormant, domain)

  @doc "Put domains to sleep for 60-90 days. Returns how many were written."
  @spec mark_dormant([String.t()]) :: non_neg_integer()
  def mark_dormant(domains), do: mark(:dormant, domains)

  @doc """
  True if a change was recorded for `domain` in the last 21-28 days. A hot
  domain ignores the stable and dormant rings: a business that just moved
  is the one worth watching weekly (Cho and Garcia-Molina: revisit in
  proportion to the observed change rate).
  """
  @spec hot?(term()) :: boolean()
  def hot?(domain), do: in_ring?(:hot, domain)

  @doc "Remember that these domains just changed. Returns how many were written."
  @spec mark_hot([String.t()]) :: non_neg_integer()
  def mark_hot(domains), do: mark(:hot, domains)

  @doc "True if the domain is a tier B or tier C business inside its refresh cadence (see LS.Crawl.Tiers)."
  @spec tiered?(term()) :: boolean()
  def tiered?(domain),
    do: Application.get_env(:ls, :tier_rings, true) and (in_ring?(:tier_b, domain) or in_ring?(:tier_c, domain))

  @doc "Mark tier B businesses (60-70 days). Returns how many were written."
  @spec mark_tier_b([String.t()]) :: non_neg_integer()
  def mark_tier_b(domains), do: mark(:tier_b, domains)

  @doc "Mark tier C businesses (120-140 days). Returns how many were written."
  @spec mark_tier_c([String.t()]) :: non_neg_integer()
  def mark_tier_c(domains), do: mark(:tier_c, domains)

  defp in_ring?(name, domain) when is_binary(domain) and domain != "" do
    case :persistent_term.get(@rings[name].key, nil) do
      %{blooms: blooms} -> Enum.any?(blooms, &Bloom.member?(&1, domain))
      _ -> false
    end
  end

  defp in_ring?(_, _), do: false

  defp mark(name, domains) when is_list(domains) do
    case :persistent_term.get(@rings[name].key, nil) do
      %{blooms: [newest | _]} ->
        n = domains |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.map(&Bloom.put(newest, &1)) |> length()
        :counters.add(ring_counter(name), 1, n)
        n

      _ ->
        0
    end
  end

  defp mark(_, _), do: 0

  defp ring_counter(name), do: :persistent_term.get(@rings[name].counter, nil) || init_ring_counter(name)

  defp init_ring_counter(name) do
    c = :counters.new(1, [:write_concurrency])
    :persistent_term.put(@rings[name].counter, c)
    c
  end


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
    daily =
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

    rings =
      Enum.reduce(@ring_names, %{}, fn name, acc ->
        prefix = Atom.to_string(name)

        stats =
          case :persistent_term.get(@rings[name].key, nil) do
            %{blooms: blooms, rotated_at: at} ->
              %{
                "#{prefix}_windows" => length(blooms),
                "#{prefix}_entries" => Enum.map(blooms, &Bloom.count/1),
                "#{prefix}_memory_mb" => blooms |> Enum.map(&Bloom.memory_mb/1) |> Enum.sum() |> Float.round(1),
                "#{prefix}_marked_total" => :counters.get(ring_counter(name), 1),
                "#{prefix}_rotated_at" => at
              }

            _ ->
              %{"#{prefix}_windows" => 0, "#{prefix}_entries" => [], "#{prefix}_memory_mb" => 0.0, "#{prefix}_marked_total" => 0, "#{prefix}_rotated_at" => nil}
          end

        Map.merge(acc, Map.new(stats, fn {k, v} -> {String.to_atom(k), v} end))
      end)

    Map.merge(daily, rings)
  end

  @impl true
  def init(_opts) do
    :ets.new(@sightings, [:set, :public, :named_table, write_concurrency: true])
    :persistent_term.put(@pt_key, for(_ <- 1..@windows, do: Bloom.new(@capacity, @fp_rate)))
    Process.send_after(self(), :rotate, @rotate_ms)
    Process.send_after(self(), :flush, @flush_ms)
    send(self(), :backfill)

    for name <- @ring_names do
      init_ring_counter(name)
      restore_ring(name)
      Process.send_after(self(), {:rotate_ring, name}, ms_until_rotation(name))
    end

    Process.send_after(self(), :save_rings, @stable_save_ms)

    Logger.info("🔁 CrawlDedup started (#{@windows} daily windows x #{@capacity} entries, suppression 7-8 days; rings: #{Enum.map_join(@ring_names, ", ", &"#{&1} #{@rings[&1].windows}x#{div(@rings[&1].period_s, 86_400)}d")})")

    {:ok, %{recorded: 0}}
  end

  # ── rings: stable, dormant, hot ───────────────────────────────────────

  defp new_bloom(name), do: Bloom.new(@rings[name].capacity, @rings[name].fp)

  @doc false
  def ring_path(name), do: Path.join(LS.State.dir(), @rings[name].file)

  @doc false
  def stable_path, do: ring_path(:stable)

  # A saved ring is rotated forward by the periods that passed while the
  # BEAM was down, so a two-week outage releases two weeks of domains
  # instead of none. Anything unreadable starts fresh: an empty ring only
  # costs fetches.
  defp restore_ring(name) do
    now = System.system_time(:second)

    ring =
      with {:ok, bin} <- File.read(ring_path(name)),
           {:ok, ring} <- decode_ring(name, bin, now) do
        Logger.info("🔁 CrawlDedup #{name} ring restored (#{Enum.map_join(ring.blooms, "/", &Bloom.count/1)} entries)")
        ring
      else
        {:error, :enoent} -> fresh_ring(name, now)
        other ->
          Logger.warning("🔁 CrawlDedup #{name} ring not restored (#{inspect(other)}), starting empty")
          fresh_ring(name, now)
      end

    :persistent_term.put(@rings[name].key, ring)
  end

  defp fresh_ring(name, now), do: %{blooms: for(_ <- 1..@rings[name].windows, do: new_bloom(name)), rotated_at: now}

  @doc false
  def decode_ring(name, bin, now) do
    windows = @rings[name].windows

    case :erlang.binary_to_term(bin, [:safe]) do
      %{v: 1, rotated_at: at, blooms: bins} when is_integer(at) and is_list(bins) and length(bins) == windows ->
        blooms = Enum.map(bins, fn b -> case Bloom.from_binary(b) do {:ok, f} -> f; :error -> new_bloom(name) end end)
        {:ok, rotate_ring(name, %{blooms: blooms, rotated_at: at}, now)}

      _ ->
        {:error, :corrupt}
    end
  rescue
    _ -> {:error, :corrupt}
  end

  @doc false
  def decode_stable(bin, now), do: decode_ring(:stable, bin, now)

  @doc false
  # Pure: advance the ring by however many whole periods separate
  # `rotated_at` from `now`; more than the ring's length means a fresh ring.
  def rotate_ring(name, %{blooms: blooms, rotated_at: at} = ring, now) do
    %{windows: windows, period_s: period} = @rings[name]
    periods = div(max(now - at, 0), period)

    cond do
      periods == 0 -> ring
      periods >= windows -> fresh_ring(name, now)
      true ->
        kept = Enum.take(blooms, windows - periods)
        %{blooms: for(_ <- 1..periods, do: new_bloom(name)) ++ kept, rotated_at: at + periods * period}
    end
  end

  @doc false
  def rotate_stable_ring(ring, now), do: rotate_ring(:stable, ring, now)

  defp ms_until_rotation(name) do
    %{rotated_at: at} = :persistent_term.get(@rings[name].key)
    max((at + @rings[name].period_s - System.system_time(:second)) * 1000, 60_000)
  end

  @doc false
  def save_ring(name) do
    case :persistent_term.get(@rings[name].key, nil) do
      %{blooms: blooms, rotated_at: at} ->
        bin = :erlang.term_to_binary(%{v: 1, rotated_at: at, blooms: Enum.map(blooms, &Bloom.to_binary/1)})
        path = ring_path(name)
        tmp = path <> ".tmp"

        with :ok <- File.write(tmp, bin), :ok <- File.rename(tmp, path) do
          :ok
        else
          err ->
            File.rm(tmp)
            Logger.warning("🔁 CrawlDedup #{name} ring not saved: #{inspect(err)}")
            err
        end

      _ ->
        :ok
    end
  end

  @doc false
  def save_stable, do: save_ring(:stable)

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

  def handle_info({:rotate_ring, name}, state) do
    ring = :persistent_term.get(@rings[name].key)
    :persistent_term.put(@rings[name].key, rotate_ring(name, ring, System.system_time(:second)))
    Process.send_after(self(), {:rotate_ring, name}, ms_until_rotation(name))
    Logger.info("🔁 CrawlDedup #{name} ring rotated")
    {:noreply, state}
  end

  def handle_info(:save_rings, state) do
    Task.start(fn -> Enum.each(@ring_names, &save_ring/1) end)
    Process.send_after(self(), :save_rings, @stable_save_ms)
    {:noreply, state}
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
    Enum.each(@ring_names, &save_ring/1)
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
                 "INSERT INTO #{LS.Schema.Tables.ctl_log()} (domain, seen_at, ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains) FORMAT TabSeparated",
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
            "SELECT DISTINCT domain FROM #{LS.Schema.Tables.enrich_log()} " <>
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
