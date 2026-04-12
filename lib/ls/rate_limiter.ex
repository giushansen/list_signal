defmodule LS.RateLimiter do
  @moduledoc "ETS-based per-user rate limiter for the explorer."

  @table :explorer_rate_limits

  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Check if a request is allowed for the given user_id.
  Returns :ok or {:error, :rate_limited}.

  Limits per minute by plan:
  - free: 10
  - starter: 30
  - pro: 120
  """
  def check(user_id, plan) do
    limit = limit_for(plan)
    now = System.system_time(:second)
    window = div(now, 60)
    key = {user_id, window}

    case :ets.update_counter(@table, key, {2, 1}, {key, 0}) do
      count when count <= limit -> :ok
      _ -> {:error, :rate_limited}
    end
  end

  defp limit_for("pro"), do: 120
  defp limit_for("starter"), do: 30
  defp limit_for(_), do: 10

  @doc """
  Returns the current usage stats for a user without incrementing the counter.
  Returns %{used: integer, limit: integer, remaining: integer, reset_in: seconds}.
  """
  def stats(user_id, plan) do
    init()
    limit = limit_for(plan)
    now = System.system_time(:second)
    window = div(now, 60)
    key = {user_id, window}

    used =
      case :ets.lookup(@table, key) do
        [{^key, count}] -> count
        [] -> 0
      end

    %{
      used: used,
      limit: limit,
      remaining: max(limit - used, 0),
      reset_in: 60 - rem(now, 60)
    }
  end

  @doc "Clean up expired windows. Call periodically."
  def sweep do
    now = System.system_time(:second)
    current_window = div(now, 60)

    :ets.tab2list(@table)
    |> Enum.each(fn {{_user_id, window} = key, _count} ->
      if window < current_window - 1, do: :ets.delete(@table, key)
    end)
  end
end
