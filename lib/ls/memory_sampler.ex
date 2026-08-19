defmodule LS.MemorySampler do
  @moduledoc """
  Publishes current VM memory usage for `LSWeb.Plugs.OverloadGuard`.

  Sampling in one process every second, rather than measuring per request,
  keeps the guard's hot path a single `:persistent_term` read. Memory does not
  move meaningfully inside a second, so the extra precision would buy nothing.

  Prefers the cgroup's own accounting (what the kernel enforces, and what
  actually killed the app) and falls back to `:erlang.memory/0` when no cgroup
  is present, as in dev and test.
  """
  use GenServer
  require Logger

  @interval_ms 1_000
  @cgroup_root "/sys/fs/cgroup"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :sample)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sample, state) do
    {bytes, limit} = read()
    LSWeb.Plugs.OverloadGuard.publish(bytes, limit)
    Process.send_after(self(), :sample, @interval_ms)
    {:noreply, state}
  end

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
