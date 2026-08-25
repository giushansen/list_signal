defmodule LS.CacheSnapshot do
  @moduledoc """
  Persists the page caches across restarts so a deploy does not start cold.

  ## Why this exists (2026-08-24)

  Caching made the product fast — ClickHouse read CPU fell from 13.7 cores to
  0.86 — but it also made it *cache-dependent*. The deploy that shipped those
  caches produced a 25-second `503` on `/top/fashion` and a load average of
  39.9, because every restart empties ETS and then boot, the warmer and real
  traffic all hit the same cold keys at once.

  The caches are small (`ls_ui_cache` is ~4 MB / 410 entries on prod) and the
  values are *derived* — recomputing them is expensive but re-reading them is
  free. So we write them to a file in the system temp dir on the way down and
  read them back on the way up. `/tmp` is the right home: it survives a deploy
  (same box, no reboot) but not a reboot, which is exactly the lifetime a
  derived cache should have.

  ## Freshness is never extended

  A restored entry gets the time it had left *minus the downtime*, so a 6-hour
  TTL cannot become "6 hours plus however long the deploy took". Restores use
  `insert_new`, so anything already recomputed since boot wins.

  ## Staggering

  Entries keep their individual remaining TTLs, which already differ because
  they were computed at different times. On top of that each one is shortened
  by a random 0–25%, so a set of keys warmed together in one burst (the cache
  warmer does exactly this) does not expire together in one burst later and
  re-create the stampede this module exists to prevent. Jitter only ever
  *shortens*, never lengthens — it cannot serve staler data than the TTL
  allows.
  """
  use GenServer
  require Logger

  # {table, shape} — `shape` says how to read/write that table's expiry field.
  #
  #   :wall_4   {key, value, expires_at_unix_seconds, inserted_at}  (LS.UICache)
  #   :mono_3   {key, value, expires_at_monotonic_ms}               (LS.LandingCache)
  #   :ctl_4    {domain, {cert_count, max_sub, first_seen, last_seen}} (LS.Cache
  #             CTL dedup) — wall-clock throughout, 14-day TTL enforced by
  #             LS.Cache's sweeper, so rows restore VERBATIM. Added 2026-08-25:
  #             every deploy wiped the dedup memory of ~1M recently-seen
  #             domains, so the poller re-enqueued them all and the fleet spent
  #             hours recrawling what it already knew.
  #
  # Monotonic time is meaningless across a restart, which is why every entry is
  # normalised to "milliseconds remaining" in the file and rebuilt on the way in.
  @tables [{:ls_ui_cache, :wall_4}, {:landing_cache, :mono_3}, {:ctl_cache, :ctl_4}]

  # LS.Cache's TTL for ctl rows (@cache_ttl there) — kept in step by a test.
  @ctl_ttl_s 1_209_600

  # A snapshot older than this is discarded: past a few hours the entries would
  # have expired anyway, and restoring them only risks serving stale numbers.
  @max_age_ms :timer.hours(6)
  # Don't bother restoring an entry with less than a minute left.
  @min_keep_ms 60_000
  # Disk guard. The master filled its disk once (2026-08-20); a cache snapshot
  # must never be the thing that does it again.
  @max_file_bytes 64 * 1024 * 1024
  @save_every_ms :timer.minutes(5)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Where the snapshot lives. Overridable in tests via `:ls, :cache_snapshot_path`."
  def path do
    Application.get_env(:ls, :cache_snapshot_path) ||
      Path.join(System.tmp_dir!(), "ls_cache_snapshot.bin")
  end

  @doc "How many entries the last restore put back — read by `LS.CacheWarmer`."
  def restored_count, do: :persistent_term.get({__MODULE__, :restored}, 0)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    n = restore()
    :persistent_term.put({__MODULE__, :restored}, n)
    schedule_save()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:save, state) do
    save()
    schedule_save()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def handle_call(:save, _from, state), do: {:reply, save(), state}

  # Runs on a graceful shutdown, which is how deploys stop the app — this is
  # the save that matters most, because it is the freshest.
  @impl true
  def terminate(_reason, _state) do
    save()
    :ok
  end

  # ── save ───────────────────────────────────────────────────────────────

  @doc """
  Write every configured table to `path/0`. Returns `{:ok, entries}`, or
  `{:error, reason}` — a failed snapshot is never fatal, it just means the next
  boot is cold.
  """
  def save do
    now_ms = System.system_time(:millisecond)
    tables = Map.new(@tables, fn {t, shape} -> {t, dump(t, shape)} end)
    count = tables |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    bin = :erlang.term_to_binary(%{saved_at: now_ms, tables: tables}, compressed: 6)

    cond do
      count == 0 ->
        {:ok, 0}

      byte_size(bin) > @max_file_bytes ->
        Logger.warning("[SNAPSHOT] skipped: #{div(byte_size(bin), 1_048_576)}MB exceeds cap")
        {:error, :too_big}

      true ->
        write_atomically(bin, count)
    end
  rescue
    e ->
      Logger.warning("[SNAPSHOT] save failed: #{Exception.message(e)}")
      {:error, :exception}
  end

  # Write to a sibling then rename: a snapshot half-written when the box dies
  # must never be readable, or the next boot restores garbage.
  defp write_atomically(bin, count) do
    tmp = path() <> ".tmp"

    with :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, path()) do
      Logger.info("[SNAPSHOT] saved #{count} entries (#{div(byte_size(bin), 1024)}KB)")
      {:ok, count}
    else
      {:error, reason} = err ->
        Logger.warning("[SNAPSHOT] save failed: #{inspect(reason)}")
        File.rm(tmp)
        err
    end
  end

  # `[{key, value, remaining_ms}]` for one table; [] if it does not exist.
  defp dump(table, shape) do
    table
    |> :ets.tab2list()
    |> Enum.flat_map(&entry_remaining(&1, shape))
  rescue
    ArgumentError -> []
  end

  @doc false
  # Pure: native row -> [{key, value, remaining_ms}], dropping non-cache and
  # already-expired rows. `landing_cache` also holds 2-tuples that belong to
  # its refresh loop, not to `cached/3`; those are not ours to persist.
  def entry_remaining(row, shape, now_wall_s \\ nil, now_mono_ms \\ nil)

  def entry_remaining({key, value, expires_at, _inserted}, :wall_4, now_s, _) do
    now_s = now_s || System.system_time(:second)
    keep(key, value, (expires_at - now_s) * 1000)
  end

  def entry_remaining({key, value, expires_at}, :mono_3, _, now_ms) do
    now_ms = now_ms || System.monotonic_time(:millisecond)
    keep(key, value, expires_at - now_ms)
  end

  def entry_remaining({key, {_cc, _sc, _fs, last_seen} = value}, :ctl_4, now_s, _)
      when is_integer(last_seen) do
    now_s = now_s || System.system_time(:second)
    keep(key, value, (last_seen + @ctl_ttl_s - now_s) * 1000)
  end

  def entry_remaining(_row, _shape, _, _), do: []

  defp keep(key, value, remaining) when is_integer(remaining) and remaining > 0,
    do: [{key, value, remaining}]

  defp keep(_, _, _), do: []

  # ── restore ────────────────────────────────────────────────────────────

  @doc """
  Read `path/0` back into ETS. Returns the number of entries restored (0 when
  there is no snapshot, it is too old, or it is unreadable).
  """
  def restore do
    with {:ok, bin} <- File.read(path()),
         {:ok, %{saved_at: saved_at, tables: tables}} <- safe_binary_to_term(bin),
         age when age <= @max_age_ms <- System.system_time(:millisecond) - saved_at do
      n = Enum.sum(for {t, rows} <- tables, do: load(t, shape_of(t), rows, age))
      Logger.info("[SNAPSHOT] restored #{n} entries (snapshot #{div(age, 1000)}s old)")
      n
    else
      {:error, :enoent} ->
        0

      age when is_integer(age) ->
        Logger.info("[SNAPSHOT] ignored: #{div(age, 60_000)} min old")
        0

      other ->
        Logger.warning("[SNAPSHOT] restore skipped: #{inspect(other)}")
        0
    end
  end

  # A corrupt or hand-edited file must not crash the boot, and must not be able
  # to construct atoms or resurrect dead pids.
  defp safe_binary_to_term(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> {:error, :corrupt}
  end

  defp shape_of(table) do
    Enum.find_value(@tables, fn {t, shape} -> if t == table, do: shape end)
  end

  defp load(_table, nil, _rows, _age), do: 0

  defp load(table, shape, rows, age) do
    now_s = System.system_time(:second)
    now_mono = System.monotonic_time(:millisecond)

    Enum.count(rows, fn {key, value, remaining} ->
      case rebuild(key, value, remaining, age, shape, now_s, now_mono) do
        nil -> false
        row -> :ets.insert_new(table, row)
      end
    end)
  rescue
    ArgumentError -> 0
  end

  @doc false
  # Pure: decide the restored row, or nil to drop it. Charges the downtime
  # against the remaining TTL and applies the 0-25% shortening jitter.
  def rebuild(key, value, remaining, age, shape, now_s, now_mono, jitter \\ nil) do
    left = remaining - age

    cond do
      left < @min_keep_ms -> nil
      shape == :ctl_4 -> build_row(key, value, left, shape, now_s, now_mono)
      true ->
        left = round(left * (1.0 - 0.25 * (jitter || :rand.uniform())))
        build_row(key, value, left, shape, now_s, now_mono)
    end
  end

  defp build_row(key, value, left, :wall_4, now_s, _), do: {key, value, now_s + div(left, 1000), now_s}
  defp build_row(key, value, left, :mono_3, _, now_mono), do: {key, value, now_mono + left}
  # Wall-clock throughout — the row IS its own freshness record; the sweeper
  # in LS.Cache expires it. Jitter is skipped: a dedup cache has no stampede.
  defp build_row(key, value, _left, :ctl_4, _, _), do: {key, value}

  defp schedule_save, do: Process.send_after(self(), :save, @save_every_ms)
end
