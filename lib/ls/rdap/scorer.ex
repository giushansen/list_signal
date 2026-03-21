defmodule LS.RDAP.Scorer do
  @moduledoc """
  Score domains based on RDAP registration data.

  - rdap_age_scoring:       -10 (< 30d) to +10 (5yr+)
  - rdap_registrar_scoring: registrar prestige + EPP status locks
  """

  @sig_table :sig_rdap_registrar

  def score(rdap_data) when is_map(rdap_data) do
    %{
      rdap_age_scoring: age_score(rdap_data[:domain_created_at]),
      rdap_registrar_scoring: registrar_score(rdap_data[:registrar]) + status_score(rdap_data[:status])
    }
  end
  def score(_), do: %{rdap_age_scoring: 0, rdap_registrar_scoring: 0}

  # Age: days since registration
  defp age_score(nil), do: 0
  defp age_score(created) when is_binary(created) do
    case parse_dt(created) do
      {:ok, dt} ->
        days = NaiveDateTime.diff(NaiveDateTime.utc_now(), dt, :day)
        cond do
          days < 30   -> -10
          days < 180  -> 0
          days < 730  -> 3
          days < 1825 -> 7
          true        -> 10
        end
      :error -> 0
    end
  end
  defp age_score(_), do: 0

  # Registrar: from signatures CSV
  defp registrar_score(nil), do: 0
  defp registrar_score(""), do: 0
  defp registrar_score(registrar) do
    lower = String.downcase(registrar)
    case :ets.info(@sig_table) do
      :undefined -> 0
      _ ->
        :ets.tab2list(@sig_table)
        |> Enum.find_value(0, fn {pattern, _, points, _} ->
          if String.contains?(lower, pattern), do: points, else: nil
        end)
    end
  end

  # Status: EPP lock codes
  defp status_score(nil), do: 0
  defp status_score(""), do: 0
  defp status_score(status_str) do
    statuses = String.downcase(status_str) |> String.split("|", trim: true)
    server_locks = Enum.count(statuses, &String.starts_with?(&1, "server"))
    client_locks = Enum.count(statuses, &String.starts_with?(&1, "client"))
    has_hold = Enum.any?(statuses, fn s -> s in ["clienthold", "serverhold", "pendingdelete"] end)
    cond do
      has_hold -> -15
      server_locks >= 2 -> 5
      client_locks >= 3 -> 2
      true -> 0
    end
  end

  defp parse_dt(str) do
    str = str |> String.replace("Z", "") |> String.replace("T", " ") |> String.slice(0, 19)
    case NaiveDateTime.from_iso8601(str) do
      {:ok, dt} -> {:ok, dt}
      _ -> :error
    end
  end
end
