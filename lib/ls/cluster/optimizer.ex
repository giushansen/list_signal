defmodule LS.Cluster.Optimizer do
  @moduledoc """
  Runs `OPTIMIZE TABLE businesses FINAL` once a day, at the quietest hour of
  the master's web traffic, so the non-FINAL reads of the product table stay
  deduplicated.

  It ran hourly until 2026-10-28. Each pass had grown from 94 s (2026-09-09,
  19M rows) to 180 s (27 runs averaging 179.9 s on 2026-10-27, 27M rows), a
  full rewrite of 11.7 GB on the 4-core box that serves customers, 5% of
  every hour. The owner's dashboard took 11 s on 2026-10-28 at 02:26 UTC,
  inside the 02:25 pass: the same explorer query ran in 3.6 s on a quiet
  box. Between passes the table gains about 0.07% duplicate rows per hour
  (0.006% measured right after a pass), so a day without a pass leaves
  under 2% duplicates: the explorer deduplicates its page anyway and counts
  are approximate by contract. 11:30 UTC is the daily minimum of web
  requests on the master (about 5K an hour against 17K at 02:00 UTC, which
  is the owner's morning; measured over 30 h on 2026-10-27/28).

  `domains_current` is NOT optimized here any more (2026-09-09). It used to
  be, at 566s per hourly pass: 3.1 hours of merge CPU and a 33 GB rewrite
  every hour on the box that serves customers, and nothing read the table
  without FINAL that cared. Its readers are point lookups with FINAL
  (get_store, the recrawl scheduler) and the tech index build, which reads
  FINAL once per six hours. Background merges still collapse it over time.
  """
  use GenServer
  require Logger

  # The daily pass starts at this UTC time (see the moduledoc for the measurement).
  @quiet_hour 11
  @quiet_minute 30
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

  defp schedule, do: Process.send_after(self(), :optimize, delay_to_quiet_hour_ms(DateTime.utc_now()))

  @doc "Milliseconds from `now` (UTC) to the next daily pass at #{@quiet_hour}:#{@quiet_minute} UTC, never under a minute."
  @spec delay_to_quiet_hour_ms(DateTime.t()) :: pos_integer()
  def delay_to_quiet_hour_ms(%DateTime{} = now) do
    today = DateTime.new!(DateTime.to_date(now), Time.new!(@quiet_hour, @quiet_minute, 0), "Etc/UTC")
    diff = DateTime.diff(today, now, :millisecond)
    if diff >= 60_000, do: diff, else: diff + :timer.hours(24)
  end
end
