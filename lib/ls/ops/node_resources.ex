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
     disk_total_gb, disk_used_gb, disk_used_pct, net_rx_bytes, net_tx_bytes,
     beam_mb}`. `net_*` are cumulative counters — subtract two readings for a rate.
  """
  def local do
    {l1, l5, l15} = loadavg()
    {mt, ma} = meminfo()
    {dt, du, dp} = disk()
    {rx, tx} = netdev()

    %{
      cores: System.schedulers_online(),
      load1: l1,
      load5: l5,
      load15: l15,
      mem_total_mb: mt,
      mem_avail_mb: ma,
      mem_used_pct: pct(mt && ma && mt - ma, mt),
      disk_total_gb: dt,
      disk_used_gb: du,
      disk_used_pct: dp,
      net_rx_bytes: rx,
      net_tx_bytes: tx,
      beam_mb: div(:erlang.memory(:total), 1_048_576)
    }
  end

  defp loadavg do
    case File.read("/proc/loadavg") do
      {:ok, s} ->
        case String.split(s, " ") do
          [a, b, c | _] -> {to_f(a), to_f(b), to_f(c)}
          _ -> {nil, nil, nil}
        end

      _ -> {nil, nil, nil}
    end
  end

  defp meminfo do
    case File.read("/proc/meminfo") do
      {:ok, s} ->
        kv = Map.new(Regex.scan(~r/^(\w+):\s+(\d+)/m, s), fn [_, k, v] -> {k, String.to_integer(v)} end)
        {kb_mb(kv["MemTotal"]), kb_mb(kv["MemAvailable"])}

      _ -> {nil, nil}
    end
  end

  # `df -Pk /` — portable, one shell-out per collection.
  defp disk do
    case System.cmd("df", ["-Pk", "/"], stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/\n\S+\s+(\d+)\s+(\d+)\s+\d+\s+(\d+)%/, out) do
          [_, total, used, pct] -> {round(String.to_integer(total) / 1_048_576), round(String.to_integer(used) / 1_048_576), String.to_integer(pct)}
          _ -> {nil, nil, nil}
        end

      _ -> {nil, nil, nil}
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

            _ -> {rx, tx}
          end
        end)

      _ -> {nil, nil}
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
