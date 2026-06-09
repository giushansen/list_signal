defmodule LS.Cluster.Optimizer do
  @moduledoc """
  Periodically runs `OPTIMIZE TABLE domains_current FINAL` so the data explorer's
  non-FINAL queries stay deduplicated.

  The explorer dropped `FINAL` from its hot queries for speed (FINAL forces a
  full-table merge on every filter click). This hourly background merge keeps the
  ReplacingMergeTree collapsed so non-FINAL reads stay clean. Master-only.
  """
  use GenServer
  require Logger

  @interval :timer.hours(1)
  # OPTIMIZE FINAL on a multi-GB table can exceed the default 10s client timeout.
  @optimize_timeout :timer.minutes(10)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:optimize, state) do
    started = System.monotonic_time(:millisecond)

    case LS.Clickhouse.query_raw("OPTIMIZE TABLE domains_current FINAL", @optimize_timeout) do
      {:ok, _} ->
        elapsed = System.monotonic_time(:millisecond) - started
        Logger.info("[Optimizer] OPTIMIZE domains_current FINAL done in #{elapsed}ms")

      {:error, reason} ->
        Logger.warning("[Optimizer] OPTIMIZE domains_current FINAL failed: #{inspect(reason)}")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :optimize, @interval)
end
