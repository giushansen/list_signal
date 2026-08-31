defmodule LS.Ops.NodeResources do
  @moduledoc """
  One node's live CPU / RAM / disk / network, read straight from `/proc` and a
  single `df` — no `sar`, no external agent. Called on every node over `:erpc`
  by `LS.Metrics.node_resources/0` for the dashboard, alerts and the weekly
  report, so the numbers are consistent everywhere.

  Everything degrades to `nil` rather than raising: a report must render even
  if one node is unreachable or on a platform without `/proc`.
  """

  @doc """
  `%{cores, load1, load5, load15, mem_total_mb, mem_avail_mb, mem_used_pct,
     mem_pressure_full_avg10, mem_pressure_full_avg60, disk_total_gb,
     disk_used_gb, disk_used_pct, net_rx_bytes, net_tx_bytes, beam_mb}`.
  `net_*` are cumulative counters — subtract two readings for a rate.

  `mem_pressure_full_*` is Linux PSI (`/proc/pressure/memory`, kernel 4.20+):
  the percentage of wall-clock time ALL runnable tasks were stalled waiting
  on memory. This is the danger signal (2026-08-30) — see
  `LS.Alerts.mem_pressure_band/1`. `mem_used_pct` alone conflates "swap in
  use, running fine" with "system is thrashing"; PSI does not, because a
  worker with 90% memory used and reclaimable page cache shows near-zero
  `full` stall time, while one actually thrashing shows real double-digit
  numbers. `nil` on any kernel too old to expose it.
  """
  def local do
    {l1, l5, l15} = loadavg()
    {mt, ma} = meminfo()
    {p10, p60} = mem_pressure()
    {dt, du, dp} = disk()
    {rx, tx} = netdev()
    {restart_result, restart_count} = restart_info()

    %{
      cores: System.schedulers_online(),
      load1: l1,
      load5: l5,
      load15: l15,
      mem_total_mb: mt,
      mem_avail_mb: ma,
      mem_used_pct: pct(mt && ma && mt - ma, mt),
      mem_pressure_full_avg10: p10,
      mem_pressure_full_avg60: p60,
      disk_total_gb: dt,
      disk_used_gb: du,
      disk_used_pct: dp,
      net_rx_bytes: rx,
      net_tx_bytes: tx,
      beam_mb: div(:erlang.memory(:total), 1_048_576),
      restart_result: restart_result,
      restart_count: restart_count
    }
  end

  @doc """
  Why THIS node's service last exited, straight from systemd, and how many
  times it has restarted since boot — the "down or restarted, and why" the
  owner asked for (2026-08-30).

  `systemctl show` on your own unit is an ordinary unprivileged read, so this
  needs no sudo and no SSH from the app. `Result` is "success" for every
  normal stop-then-start (an admin restart, a deploy, systemd's own
  `Restart=always` cycling a process that exited cleanly) and something else
  — "oom-kill", "signal", "exit-code", "timeout", "watchdog" — only when the
  PREVIOUS instance died for a real reason. Alerts key on `restart_count`, so
  the same restart is reported once, not on every 15-minute tick.

  One `System.cmd` for both fields, not two: `local/0` used to call this
  once per field, forking `systemctl` twice on every `erpc`-polled
  collection. Forking a process is exactly the slow path on a node under
  real memory pressure (swap-in page faults on the new process's pages), so
  the extra fork made `local/0` itself more likely to blow the master's 3s
  erpc timeout right when a node was already thrashing — turning one real
  memory-pressure event into a second, confusing "node unmonitored" alert
  (2026-08-31).
  """
  def restart_info do
    unit = "listsignal@#{System.get_env("LS_ROLE", "worker")}"

    case System.cmd("systemctl", ["show", unit, "-p", "Result", "-p", "NRestarts"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {parse_restart_info(out, :result), parse_restart_info(out, :count)}
      _ -> {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  @doc false
  def parse_restart_info(out, :result) do
    case Regex.run(~r/^Result=(\S+)/m, out) do
      [_, r] -> r
      _ -> nil
    end
  end

  def parse_restart_info(out, :count) do
    case Regex.run(~r/^NRestarts=(\d+)/m, out) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  defp loadavg do
    case File.read("/proc/loadavg") do
      {:ok, s} ->
        case String.split(s, " ") do
          [a, b, c | _] -> {to_f(a), to_f(b), to_f(c)}
          _ -> {nil, nil, nil}
        end

      _ ->
        {nil, nil, nil}
    end
  end

  # The "full" line: 100% means every runnable task was stalled on memory
  # for the whole window, i.e. real thrashing, not just "memory is full".
  defp mem_pressure do
    case File.read("/proc/pressure/memory") do
      {:ok, s} ->
        case Regex.run(~r/^full avg10=([\d.]+) avg60=([\d.]+)/m, s) do
          [_, a10, a60] -> {to_f(a10), to_f(a60)}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  defp meminfo do
    case File.read("/proc/meminfo") do
      {:ok, s} ->
        kv =
          Map.new(Regex.scan(~r/^(\w+):\s+(\d+)/m, s), fn [_, k, v] ->
            {k, String.to_integer(v)}
          end)

        {kb_mb(kv["MemTotal"]), kb_mb(kv["MemAvailable"])}

      _ ->
        {nil, nil}
    end
  end

  # `df -Pk /` — portable, one shell-out per collection.
  defp disk do
    case System.cmd("df", ["-Pk", "/"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/\n\S+\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)%/, out) do
          [_, total, used, pct] ->
            {round(String.to_integer(total) / 1_048_576),
             round(String.to_integer(used) / 1_048_576), String.to_integer(pct)}

          _ ->
            {nil, nil, nil}
        end

      _ ->
        {nil, nil, nil}
    end
  rescue
    _ -> {nil, nil, nil}
  end

  # Sum rx/tx bytes across real interfaces (skip lo and virtual wg/docker/veth).
  defp netdev do
    case File.read("/proc/net/dev") do
      {:ok, s} ->
        Enum.reduce(String.split(s, "\n"), {0, 0}, fn line, {rx, tx} ->
          case Regex.run(~r/^\s*([\w-]+):\s+(\d+)(?:\s+\d+){7}\s+(\d+)/, line) do
            [_, iface, r, t] ->
              if iface in ["lo"] or String.starts_with?(iface, ["wg", "docker", "veth", "br-"]),
                do: {rx, tx},
                else: {rx + String.to_integer(r), tx + String.to_integer(t)}

            _ ->
              {rx, tx}
          end
        end)

      _ ->
        {nil, nil}
    end
  end

  defp kb_mb(nil), do: nil
  defp kb_mb(kb), do: div(kb, 1024)
  defp pct(nil, _), do: nil
  defp pct(_, nil), do: nil
  defp pct(_, 0), do: nil
  defp pct(used, total), do: round(100 * used / total)

  defp to_f(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end
end
