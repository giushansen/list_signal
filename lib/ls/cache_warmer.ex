defmodule LS.CacheWarmer do
  @moduledoc """
  Fills the page cache after boot so the first real visitor never pays a cold
  assembly.

  The cache lives in the BEAM heap, so it is empty after every deploy and
  every restart. A cold `/tech` page costs ~7 heavy ClickHouse scans; measured
  on a freshly restarted box that took over a minute, and single-flight means
  everyone waiting on that key waits with it. Warming turns "the first
  visitor after a deploy has a terrible time" into "nobody does".

  Deliberately sequential and unhurried: warming exists to avoid load, so it
  must not create any. One page at a time, spaced out, after a boot delay —
  the goal is to be finished before traffic notices, not to be fast.
  """
  use GenServer
  require Logger

  # Let the app finish booting (EXLA, reference data) before adding work.
  @start_delay_ms 90_000
  # Space out warms so this never competes with real requests.
  @spacing_ms 750
  @top_techs 60
  @top_stores 120

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Warm now, off the caller's process (used after a manual cache flush)."
  def warm_async, do: Process.send_after(__MODULE__, :warm, 0)

  @impl true
  def init(_opts) do
    if enabled?() do
      Process.send_after(self(), :warm, @start_delay_ms)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:warm, state) do
    t0 = System.monotonic_time(:millisecond)
    techs = warm_techs()
    stores = warm_stores()

    Logger.info(
      "[WARM] cache primed: #{techs} tech pages, #{stores} store pages in " <>
        "#{div(System.monotonic_time(:millisecond) - t0, 1000)}s"
    )

    {:noreply, state}
  end

  # Warming must never crash the app or block boot; a failed warm just means a
  # slower first visitor, which is the situation we were already in.
  defp warm_techs do
    case LS.Clickhouse.shopify_tech_names() do
      {:ok, rows} ->
        rows
        |> Enum.take(@top_techs)
        |> Enum.reduce(0, fn [name | _], acc ->
          safely(fn -> LSWeb.TechController.warm(name) end)
          Process.sleep(@spacing_ms)
          acc + 1
        end)

      _ ->
        0
    end
  end

  defp warm_stores do
    case LS.Clickhouse.all_shopify_domains(@top_stores) do
      {:ok, rows} ->
        rows
        |> Enum.reduce(0, fn [domain], acc ->
          safely(fn -> LSWeb.StoreController.warm(domain) end)
          Process.sleep(@spacing_ms)
          acc + 1
        end)

      _ ->
        0
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.debug("[WARM] skipped: #{Exception.message(e)}")
  catch
    _, _ -> :ok
  end

  # Off in dev/test: warming a developer laptop against a full local database
  # is pure cost.
  defp enabled?, do: System.get_env("LS_ROLE") == "master"
end
