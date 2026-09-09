defmodule LS.Cluster.Optimizer do
  @moduledoc """
  Runs `OPTIMIZE TABLE businesses FINAL` every hour so the explorer's
  non-FINAL reads of the product table stay deduplicated.

  The explorer dropped `FINAL` from its hot queries for speed (FINAL forces a
  merge at read time on every filter click). This hourly background merge
  keeps the ReplacingMergeTree collapsed so those reads stay clean: ~94s per
  pass, 0.07% duplicate rows between passes (13,077 of 19.2M, 2026-09-09).
  Master-only.

  `domains_current` is NOT optimized here any more (2026-09-09). It used to
  be, at 566s per hourly pass: 3.1 hours of merge CPU and a 33 GB rewrite
  every hour on the box that serves customers, and nothing read the table
  without FINAL that cared. Its readers are point lookups with FINAL
  (get_store, the recrawl scheduler) and the tech index build, which reads
  FINAL once per six hours. Background merges still collapse it over time.
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
    # ReplacingMergeTree only collapses rows at merge time. `businesses` is
    # written every 5 minutes by the compactor, so without this it accumulates
    # one row per refresh per domain — measured at 5,691 duplicates across
    # 18,362 domains before this ran. Readers that forget FINAL then see the
    # same company twice, with the stale row winning by luck of ordering.
    Enum.each(["businesses"], fn table ->
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
