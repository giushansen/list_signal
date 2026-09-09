defmodule LS.Throttle do
  @moduledoc """
  Fixed-window counters for things that cost money when abused.

  Security audit 2026-09-09: the login and sign-up forms sent a magic link on
  every submit with no limit, so anyone could make Mailgun send unbounded
  mail from listsignal.com (billed per message, and each bounce hurts the
  domain's reputation). Five links per address per hour and a fleet-wide
  hourly ceiling stop that; a real person never notices either.

  Local to the node (one web node), fails open when the table is missing so
  a limiter bug can never lock people out. `LSWeb.ApiRateLimiter` is the
  same idea with a one-minute window, kept separate because the API's
  limits are per key and per plan.
  """
  use GenServer

  @table :ls_throttle

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  True when this `key` under `scope` is still within `limit` hits in the
  current `window_s`-second window. Counts the hit.
  """
  @spec allow?(atom(), term(), pos_integer(), pos_integer()) :: boolean()
  def allow?(scope, key, limit, window_s) do
    now = System.system_time(:second)
    window = div(now, window_s)
    counter_key = {scope, key, window}
    # Third element: when this window's counter can be swept.
    :ets.update_counter(@table, counter_key, {2, 1}, {counter_key, 0, (window + 1) * window_s + 60}) <= limit
  rescue
    ArgumentError -> true
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, :timer.minutes(10))
end
