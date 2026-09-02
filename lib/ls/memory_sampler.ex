defmodule LS.MemorySampler do
  @moduledoc """
  Publishes current VM memory usage for `LSWeb.Plugs.OverloadGuard`.

  Sampling in one process every second, rather than measuring per request,
  keeps the guard's hot path a single `:persistent_term` read. Memory does not
  move meaningfully inside a second, so the extra precision would buy nothing.

  Prefers the cgroup's own accounting (what the kernel enforces, and what
  actually killed the app) and falls back to `:erlang.memory/0` when no cgroup
  is present, as in dev and test.

  ## Watch-zone logging (2026-09-01)

  `LS.Ops.MemoryForensics` snapshots every 5 minutes, which is too coarse for
  a fast spike: on 09-01 memory went from ~3.3G to the 7.5G that tripped
  `OverloadGuard`'s shed in under 8 minutes, and the 5-minute snapshots
  straddled the whole climb without capturing it — the forensics existed and
  still could not say what grew. This process already samples every second
  anyway, so logging at that resolution once usage crosses `@watch_ratio`
  costs nothing extra to compute, only to print. Edge-triggered plus a
  periodic reminder while still elevated, not every second, so a genuine
  multi-minute excursion is not thousands of near-identical log lines.

  `@watch_ratio` was 0.40 for its first day and turned out to sit AT normal
  baseline (steady-state readings run 3.7-4.3G of the 9.2G limit, i.e.
  40-47%), so it logged "entered watch zone" every few minutes around the
  clock instead of only for a real excursion -- signal indistinguishable
  from noise. Raised to 0.55 (~5.1G): comfortably above the noisiest normal
  baseline observed, still well before OverloadGuard's 0.80 shed ratio.
  """
  use GenServer
  require Logger

  @interval_ms 1_000
  @cgroup_root "/sys/fs/cgroup"
  # 2026-09-02: was 0.40 (half OverloadGuard's shed ratio) but that sat at or
  # below normal steady-state usage (3.7-4.3G of 9.2G, i.e. 40-47%), so it
  # fired on ordinary baseline noise instead of real excursions. 0.55 sits
  # above the noisiest baseline actually observed and still well before the
  # 0.80 shed ratio.
  @watch_ratio 0.55
  @reminder_every_n_samples 10

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :sample)
    {:ok, %{watching?: false, since_log: 0}}
  end

  @impl true
  def handle_info(:sample, state) do
    {bytes, limit} = read()
    LSWeb.Plugs.OverloadGuard.publish(bytes, limit)
    state = log_watch_zone(bytes, limit, state)
    Process.send_after(self(), :sample, @interval_ms)
    {:noreply, state}
  end

  @doc "True once usage is far enough above baseline to be worth a trail, before any request is shed."
  @spec in_watch_zone?(number(), number()) :: boolean()
  def in_watch_zone?(bytes, limit), do: limit > 0 and bytes > limit * @watch_ratio

  defp log_watch_zone(bytes, limit, state) do
    cond do
      not in_watch_zone?(bytes, limit) ->
        %{state | watching?: false, since_log: 0}

      not state.watching? ->
        Logger.warning("[MEM-WATCH] entered watch zone: #{mb(bytes)}MB of #{mb(limit)}MB limit")
        %{state | watching?: true, since_log: 0}

      state.since_log + 1 >= @reminder_every_n_samples ->
        Logger.warning("[MEM-WATCH] still elevated: #{mb(bytes)}MB of #{mb(limit)}MB limit")
        %{state | since_log: 0}

      true ->
        %{state | since_log: state.since_log + 1}
    end
  end

  defp mb(bytes), do: div(bytes, 1_048_576)

  # The app's own cgroup path comes from /proc/self/cgroup. Reading
  # /sys/fs/cgroup/memory.current directly gives the ROOT cgroup unless the
  # namespace is delegated — which systemd does not do here, so the first
  # version silently sampled the wrong scope and fell back to a notional
  # 32G ceiling, leaving the guard inert.
  defp read do
    with {:ok, raw} <- File.read("/proc/self/cgroup"),
         path when is_binary(path) <- parse_cgroup_path(raw),
         {:ok, cur} <- File.read(Path.join([@cgroup_root, path, "memory.current"])),
         {bytes, _} <- Integer.parse(String.trim(cur)),
         {:ok, high} <- File.read(Path.join([@cgroup_root, path, "memory.high"])),
         trimmed <- String.trim(high),
         true <- trimmed != "max",
         {limit, _} <- Integer.parse(trimmed) do
      {bytes, limit}
    else
      _ -> fallback()
    end
  end

  # cgroup v2 line: "0::/system.slice/.../listsignal@master.service"
  defp parse_cgroup_path(raw) do
    raw
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 3) do
        ["0", "", path] -> String.trim_leading(path, "/")
        _ -> nil
      end
    end)
  end

  # No cgroup (dev, test, or an unlimited unit): fall back to the BEAM's own
  # accounting against a generous notional ceiling, so the guard stays inert
  # rather than shedding on a developer laptop.
  defp fallback do
    {:erlang.memory(:total), 32 * 1024 * 1024 * 1024}
  end
end
