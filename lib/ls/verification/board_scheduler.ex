defmodule LS.Verification.BoardScheduler do
  @moduledoc """
  Pipeline 3 cadence for job-platform data. Master only.

  Daily: harvest new board slugs out of `biz_career`, resync the stalest
  boards from their platforms' public JSON, and advance the Welcome to the
  Jungle directory ingest by one page budget.

  Runs are deliberately serial and off-peak-ish (first run ~30 min after
  boot, then every 24h): every downstream system — ClickHouse inserts, the
  compactor, worker sidecars — treats this as background trickle, never a
  burst.
  """
  use GenServer
  require Logger

  @first_run_ms 30 * 60 * 1000
  @cycle_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Kick a cycle now (manual/ops use)."
  def run_now, do: send(__MODULE__, :cycle) && :ok

  @impl true
  def init(opts) do
    if Keyword.get(opts, :enabled, System.get_env("LS_ROLE") == "master") do
      Process.send_after(self(), :cycle, @first_run_ms)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cycle, state) do
    t0 = System.monotonic_time(:millisecond)

    safely(fn -> LS.Verification.HRBoards.harvest_from_careers() end)
    safely(fn -> LS.Verification.HRBoards.sync_stale() end)
    safely(fn -> LS.Verification.WTTJ.ingest() end)
    safely(fn -> LS.Verification.WTTJ.resolve_via_profiles() end)

    Logger.info("[BOARDS] cycle finished in #{div(System.monotonic_time(:millisecond) - t0, 60_000)}m")
    Process.send_after(self(), :cycle, @cycle_ms)
    {:noreply, state}
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.error("[BOARDS] step failed: #{Exception.message(e)}")
  catch
    kind, reason -> Logger.error("[BOARDS] step #{kind}: #{inspect(reason)}")
  end
end
