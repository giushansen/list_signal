defmodule LS.Ops.MemoryForensics do
  @moduledoc """
  A black-box recorder for the master's recurring memory-limit stalls.

  ## Why this exists (2026-08-30)

  The master has been restarting roughly once a day since the CT ingestion
  rewrite multiplied inflow ~6x: memory passes its cgroup ceiling, swap is
  off by design (a stalled BEAM beats a swap-thrashed one for a crawler that
  must stay polite), the kernel throttles the process until it stalls, and
  the watchdog restarts it. Two real contributors were found and fixed
  (`recently_crawled`'s oversized TTL, `ctl_cache` growth toward its cap),
  which roughly halved the crash frequency — but a live measurement on
  2026-08-30 found a **~1.37 GB gap between the cgroup's view of memory and
  what `:erlang.memory/0` reports**, stable over a 9-minute sample but of
  unknown long-run trend. That gap is almost certainly the EXLA/XLA native
  runtime backing the ML classifier, which BEAM's own instrumentation cannot
  see AT ALL — no ETS table, no process heap, nothing `:erlang.memory/0`
  tracks explains it.

  Rather than keep guessing under time pressure during a live incident, this
  module keeps a running record so the NEXT crash has a trail: what was
  large, whether the gap was still stable or had started climbing, which
  processes held the most memory. `ops_memory_snapshots` in ClickHouse is the
  archive; the extra-detail path below also puts the full breakdown straight
  into the journal, because ClickHouse itself may be the thing under memory
  pressure when it matters most.

  Master only — see `LS.Application`.
  """

  use GenServer
  require Logger

  alias LS.Clickhouse

  @interval_ms :timer.minutes(5)
  # Matches the systemd MemoryHigh in devops/listsignal/systemd/20-memory.conf.
  # Kept in this module (not read from systemd) because it is only ever used
  # to decide when to log LOUDER, not to enforce anything — an app-side
  # mismatch with the real cgroup limit costs nothing but a slightly early or
  # late extra log line.
  @configured_ceiling_mb 9_216
  @alarm_fraction 0.80
  @top_n 12

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Take and persist one snapshot right now. Returns the snapshot map."
  def snapshot_now, do: capture_and_record()

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, 30_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @interval_ms)
    capture_and_record()
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── capture ─────────────────────────────────────────────────────────────

  defp capture_and_record do
    snap = build_snapshot()
    if snap.alarm == 1, do: log_alarm(snap)
    persist(snap)
    snap
  rescue
    e ->
      Logger.warning("[MEMFORENSICS] capture failed: #{Exception.message(e)}")
      %{}
  end

  @doc false
  def build_snapshot do
    self_rss_mb = self_rss_mb()
    m = :erlang.memory()
    erlang_total_mb = div(m[:total], 1_048_576)

    %{
      node: node_name(),
      at: DateTime.utc_now(),
      self_rss_mb: self_rss_mb,
      erlang_total_mb: erlang_total_mb,
      native_gap_mb: self_rss_mb - erlang_total_mb,
      processes_mb: div(m[:processes], 1_048_576),
      ets_mb: div(m[:ets], 1_048_576),
      binary_mb: div(m[:binary], 1_048_576),
      top_ets: top_ets(),
      top_processes: top_processes(),
      alarm: alarm?(self_rss_mb)
    }
  end

  defp alarm?(self_rss_mb),
    do: if(self_rss_mb >= @configured_ceiling_mb * @alarm_fraction, do: 1, else: 0)

  defp self_rss_mb do
    case File.read("/proc/self/status") do
      {:ok, s} ->
        case Regex.run(~r/^VmRSS:\s+(\d+)\s+kB/m, s) do
          [_, kb] -> div(String.to_integer(kb), 1024)
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp top_ets do
    :ets.all()
    |> Enum.map(fn t ->
      name = ets_name(t)
      bytes = (:ets.info(t, :memory) || 0) * :erlang.system_info(:wordsize)
      %{name: to_string(name), mb: div(bytes, 1_048_576), rows: :ets.info(t, :size) || 0}
    end)
    |> Enum.sort_by(& &1.mb, :desc)
    |> Enum.take(@top_n)
    |> Jason.encode!()
  rescue
    _ -> "[]"
  end

  defp top_processes do
    Process.list()
    |> Enum.map(&process_summary/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.mb, :desc)
    |> Enum.take(@top_n)
    |> Jason.encode!()
  rescue
    _ -> "[]"
  end

  # Info calls on a process racing to exit return nil, never raise — treated
  # as "gone", not as a snapshot failure.
  defp process_summary(pid) do
    case Process.info(pid, [:memory, :message_queue_len, :registered_name, :dictionary]) do
      nil ->
        nil

      info ->
        name = registered_or_initial(info, pid)

        %{
          name: name,
          mb: Float.round(info[:memory] / 1_048_576, 2),
          mailbox: info[:message_queue_len]
        }
    end
  end

  defp ets_name(t) do
    :ets.info(t, :name)
  rescue
    ArgumentError -> t
  end

  defp registered_or_initial(info, pid) do
    case info[:registered_name] do
      [] ->
        info[:dictionary]
        |> List.wrap()
        |> Keyword.get(:"$initial_call")
        |> case do
          {mod, fun, arity} -> "#{inspect(mod)}.#{fun}/#{arity}"
          _ -> inspect(pid)
        end

      name ->
        to_string(name)
    end
  end

  defp node_name, do: Node.self() |> to_string()

  # ── persist ─────────────────────────────────────────────────────────────

  defp persist(%{node: _} = snap) do
    row =
      Jason.encode!(%{
        node: snap.node,
        # ClickHouse's DateTime type wants "YYYY-MM-DD HH:MM:SS" — no "T",
        # no fractional seconds, no "Z". ISO8601 with a naive strip broke on
        # the first real insert ("expected '\"' before: '.173644'").
        at:
          snap.at
          |> DateTime.truncate(:second)
          |> NaiveDateTime.to_string()
          |> String.replace("T", " "),
        self_rss_mb: snap.self_rss_mb,
        erlang_total_mb: snap.erlang_total_mb,
        native_gap_mb: snap.native_gap_mb,
        processes_mb: snap.processes_mb,
        ets_mb: snap.ets_mb,
        binary_mb: snap.binary_mb,
        top_ets: snap.top_ets,
        top_processes: snap.top_processes,
        alarm: snap.alarm
      })

    case Clickhouse.insert_raw("INSERT INTO ops_memory_snapshots FORMAT JSONEachRow", row) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[MEMFORENSICS] persist failed: #{inspect(reason)}")
    end
  end

  defp persist(_), do: :ok

  # Belt-and-suspenders: ClickHouse may itself be under memory pressure during
  # the exact incident this exists to explain, so the full detail also goes to
  # the journal, which the watchdog and every other alert already rely on.
  defp log_alarm(snap) do
    Logger.warning(
      "[MEMFORENSICS] ALARM: RSS #{snap.self_rss_mb}MB >= #{round(@configured_ceiling_mb * @alarm_fraction)}MB " <>
        "(#{round(@alarm_fraction * 100)}% of #{@configured_ceiling_mb}MB ceiling). " <>
        "erlang=#{snap.erlang_total_mb}MB native_gap=#{snap.native_gap_mb}MB " <>
        "ets=#{snap.ets_mb}MB processes=#{snap.processes_mb}MB binary=#{snap.binary_mb}MB\n" <>
        "top_ets=#{snap.top_ets}\ntop_processes=#{snap.top_processes}"
    )
  end
end
