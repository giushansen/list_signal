defmodule LS.UICache do
  @moduledoc """
  The single cache for everything the web tier serves.

  Three properties matter, each learned from an incident:

  **Single-flight.** On a miss, exactly ONE caller computes; the rest wait for
  its result. Without this a cold key under load is a self-inflicted DDoS — a
  2026-08-19 load test put 25 concurrent requests on one cold `/tech` page and
  all 25 ran the same seven 118M-row scans, giving 1 req/s and 34% timeouts.

  **Bounded.** Entries and their memory are capped, oldest evicted first. The
  cache lives in the BEAM heap (see below), and an unbounded cache would grow
  into the memory limit that caused eight web outages. A cap is not a nicety
  here; it is what keeps the box up.

  **TTL matched to the data, not to the traffic.** Measured on prod: an
  individual business is recrawled every 8.1 days (median 3), and a tech
  aggregate moves 1.9% in six hours. So a 6h page cache is roughly 30x fresher
  than the data behind it. The exception is the live feeds, where freshness IS
  the product — those get 30 seconds.

  ## Where this lives

  ETS: in-memory, inside the BEAM process. Therefore it is **per-node**, it
  **counts against the service's memory limit**, and it is **empty after every
  restart and deploy** — which is exactly when a stampede would hurt most,
  hence single-flight.

  ## Adding a cache

  Use a profile, do not invent a TTL at the call site:

      UICache.fetch(:tech_page, {:tech, name}, fn -> assemble(name) end)

  Profiles are declared in `@profiles` below so every cached thing in the
  product is visible in one place.
  """

  use GenServer
  require Logger

  @table :ls_ui_cache
  @inflight :ls_ui_cache_inflight

  # name => {ttl_seconds, description}
  @profiles %{
    # Public pages: identical for every visitor, data changes slower than the TTL.
    tech_page: {21_600, "/tech/* assembled page data"},
    compare_page: {21_600, "/compare/* assembled page data"},
    # Not whole store pages — there are 731k of them. Only the aggregates they
    # SHARE (counts per business-model + country), which is a few hundred keys.
    store_aggregate: {21_600, "per-model/country counts shown on store pages"},
    # Whole assembled store pages. Safe despite 731k possible keys because the
    # LRU bound evicts the cold tail — only the trafficked head stays resident.
    store_page: {21_600, "assembled /shopify/* and /website/* page data"},
    # Live feeds: freshness is the product, so seconds not hours.
    feed: {30, "latest-shopify-stores and latest-saas-businesses"},
    # Dashboard: shareable parts only. Result rows are never cached.
    dropdown: {1_800, "filter dropdown option lists"},
    segment_counts: {600, "segment button counts"},
    filter_count: {300, "total for a filter set"},
    sitemap_techs: {21_600, "techs with enough Shopify stores to earn a URL"}
  }

  # Hard ceilings. 5k entries of page data is tens of MB — a rounding error
  # against the 6G limit, and enough for the head of the traffic distribution.
  # The long tail of 731k store pages is visited too rarely to be worth RAM.
  @max_entries 5_000
  @max_bytes 200 * 1024 * 1024
  @sweep_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "TTL and description for each profile — used by the admin view and tests."
  def profiles, do: @profiles

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    :ets.new(@inflight, [:set, :public, :named_table, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @doc """
  Return the cached value for `key`, or compute it under `profile`'s TTL.

  Concurrent callers that miss the same key do NOT all compute: the first
  claims the key and the others wait for its result. A `{:error, _}` is
  returned but never cached — pinning a transient ClickHouse failure for six
  hours would turn a blip into an outage.
  """
  def fetch(profile, key, fun) when is_map_key(@profiles, profile) do
    full_key = {profile, key}

    case lookup(full_key) do
      {:ok, value} -> value
      :miss -> compute(profile, full_key, fun)
    end
  end

  @doc "Drop one entry, or a whole profile with `invalidate(:tech_page)`."
  def invalidate(profile) when is_map_key(@profiles, profile) do
    :ets.match_delete(@table, {{profile, :_}, :_, :_, :_})
    :ok
  end

  def invalidate(profile, key), do: :ets.delete(@table, {profile, key})

  @doc "Entry count, bytes and per-profile breakdown — for the admin dashboard."
  def stats do
    info = :ets.info(@table)
    bytes = (info[:memory] || 0) * :erlang.system_info(:wordsize)

    by_profile =
      @profiles
      |> Map.keys()
      |> Map.new(fn p -> {p, :ets.select_count(@table, [{{{p, :_}, :_, :_, :_}, [], [true]}])} end)

    %{entries: info[:size] || 0, bytes: bytes, max_entries: @max_entries, by_profile: by_profile}
  end

  # ── internals ──────────────────────────────────────────────────────────

  defp lookup(full_key) do
    now = System.system_time(:second)

    case :ets.lookup(@table, full_key) do
      [{^full_key, value, expires_at, _inserted}] when expires_at > now ->
        {:ok, value}

      _ ->
        :miss
    end
  end

  defp compute(profile, full_key, fun) do
    # Claim the key. insert_new is atomic, so exactly one caller wins.
    if :ets.insert_new(@inflight, {full_key, self()}) do
      try do
        value = fun.()
        store(profile, full_key, value)
        value
      after
        :ets.delete(@inflight, full_key)
      end
    else
      await(full_key, fun)
    end
  end

  # Someone else is computing. Poll briefly for their result rather than
  # duplicating the work. If they crash or exceed the wait, compute directly —
  # a slow page is always better than a hung one.
  defp await(full_key, fun, waited \\ 0)

  # Absolute ceiling so a wedged key cannot hang a request forever.
  defp await(full_key, fun, waited) when waited >= 60_000 do
    Logger.warning("[UICache] waited #{waited}ms for #{inspect(full_key)}, computing directly")
    fun.()
  end

  defp await(full_key, fun, waited) do
    Process.sleep(25)

    case lookup(full_key) do
      {:ok, value} ->
        value

      :miss ->
        # Wait as long as the COMPUTER IS ALIVE, not a fixed deadline. A fixed
        # 10s gave up on assemblies that legitimately take 14s cold, so every
        # waiter stampeded exactly when the herd was largest — the 2026-08-19
        # load test showed 150 timeouts on one cold /tech page for this
        # reason. Liveness is the correct condition: if the computer died the
        # claim is stale and we must compute; if it is working we must wait.
        case :ets.lookup(@inflight, full_key) do
          [{^full_key, pid}] ->
            if Process.alive?(pid) do
              await(full_key, fun, waited + 25)
            else
              :ets.delete(@inflight, full_key)
              fun.()
            end

          [] ->
            # Finished without storing (an error result) — compute our own.
            fun.()
        end
    end
  end

  defp store(profile, full_key, value) do
    case value do
      {:error, _} ->
        :ok

      _ ->
        {ttl, _desc} = Map.fetch!(@profiles, profile)
        now = System.system_time(:second)
        :ets.insert(@table, {full_key, value, now + ttl, now})
        enforce_bounds()
    end
  end

  # Evict oldest-inserted first when over either ceiling. Cheap because it only
  # runs on insert and only walks when actually over the limit.
  defp enforce_bounds do
    info = :ets.info(@table)
    bytes = (info[:memory] || 0) * :erlang.system_info(:wordsize)

    if (info[:size] || 0) > @max_entries or bytes > @max_bytes do
      drop = max(div(@max_entries, 10), (info[:size] || 0) - @max_entries)

      :ets.tab2list(@table)
      |> Enum.sort_by(fn {_k, _v, _exp, inserted} -> inserted end)
      |> Enum.take(drop)
      |> Enum.each(fn {k, _, _, _} -> :ets.delete(@table, k) end)

      Logger.info("[UICache] evicted #{drop} entries (size #{info[:size]}, #{div(bytes, 1_048_576)}MB)")
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    expired = :ets.select_delete(@table, [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
    if expired > 0, do: Logger.debug("[UICache] swept #{expired} expired")
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
end
