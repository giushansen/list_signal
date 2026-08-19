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
  @cgroup_current "/sys/fs/cgroup/memory.current"
  @cgroup_high "/sys/fs/cgroup/memory.high"

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

  # In a systemd cgroup the app sees its OWN limits at /sys/fs/cgroup/*, which
  # is what the kernel enforces against it.
  defp read do
    with {:ok, cur} <- File.read(@cgroup_current),
         {bytes, _} <- Integer.parse(String.trim(cur)),
         {:ok, high} <- File.read(@cgroup_high),
         trimmed <- String.trim(high),
         true <- trimmed != "max",
         {limit, _} <- Integer.parse(trimmed) do
      {bytes, limit}
    else
      _ -> fallback()
    end
  end

  # No cgroup (dev, test, or an unlimited unit): fall back to the BEAM's own
  # accounting against a generous notional ceiling, so the guard stays inert
  # rather than shedding on a developer laptop.
  defp fallback do
    {:erlang.memory(:total), 32 * 1024 * 1024 * 1024}
  end
end
