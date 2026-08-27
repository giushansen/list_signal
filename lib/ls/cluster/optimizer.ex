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
    # Both product tables are ReplacingMergeTree, which only collapses rows at
    # merge time. `businesses` is written every 5 minutes by the compactor, so
    # without this it accumulates one row per refresh per domain — measured at
    # 5,691 duplicates across 18,362 domains before this ran. Readers that
    # forget FINAL then see the same company twice, with the stale row winning
    # by luck of ordering.
    Enum.each(["domains_current", "businesses"], fn table ->
      started = System.monotonic_time(:millisecond)

      # background pool: OPTIMIZE FINAL runs for minutes and must never hold a
      # connection the web tier needs (2026-08-27 outage).
      case LS.Clickhouse.query_raw("OPTIMIZE TABLE #{table} FINAL", @optimize_timeout, background: true) do
        {:ok, _} ->
          Logger.info("[Optimizer] OPTIMIZE #{table} FINAL done in #{System.monotonic_time(:millisecond) - started}ms")

        {:error, reason} ->
          Logger.warning("[Optimizer] OPTIMIZE #{table} FINAL failed: #{inspect(reason)}")
      end
    end)

    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :optimize, @interval)
end
