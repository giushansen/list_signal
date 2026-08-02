defmodule LS.UICache do
  @moduledoc """
  TTL cache for dashboard queries whose answers are identical for every user.

  The explorer was re-running the same ClickHouse work per click: opening the
  Tech dropdown ran a DISTINCT over 7.7M rows, first paint re-counted the
  unfiltered table, and every mount re-counted all six segment presets. None
  of those answers change meaningfully inside a few minutes, and none depend
  on who is asking — so the N-th user (and the N-th click) should pay ETS
  lookup time, not ClickHouse time.

  Not part of `LS.Cache` because lifetimes differ by orders of magnitude:
  crawler caches hold for 14-90 days and guard politeness; these hold for
  minutes and guard latency.
  """

  use GenServer
  require Logger

  @table :ls_ui_cache

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Return the cached value for `key`, or run `fun`, cache its result for
  `ttl_seconds`, and return it.

  A `{:error, _}` result is returned but NOT cached — caching a transient
  ClickHouse failure would pin every user to an error page for the TTL.
  """
  def fetch(key, ttl_seconds, fun) do
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now ->
        value

      _ ->
        value = fun.()

        case value do
          {:error, _} -> :ok
          _ -> :ets.insert(@table, {key, value, now + ttl_seconds})
        end

        value
    end
  end

  @doc "Drop one cached entry (for tests and manual refresh)."
  def invalidate(key), do: :ets.delete(@table, key)
end
