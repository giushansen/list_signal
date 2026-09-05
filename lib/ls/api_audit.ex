defmodule LS.ApiAudit do
  @moduledoc """
  The audit trail for the public API/MCP: one ClickHouse row per successful
  call answering who (user, plan, key), when, how (surface + endpoint), and
  what was read (target domain, search filters, result count).

  Written fully async (fire-and-forget task): the analytics must never cost
  a request a millisecond, and a lost row under crash costs a row of
  analytics, not a customer anything. Metabase reads `api_request_log`
  directly (`metabase/queries/local/api_usage.sql`); Umami keeps the
  event-level pulse with the same event names.
  """

  alias LS.Clickhouse

  @doc "Log one successful API call. Fire-and-forget."
  def log_async(meta) when is_map(meta) do
    Task.Supervisor.start_child(LS.TaskSupervisor, fn ->
      Clickhouse.query_raw(
        "INSERT INTO api_request_log (user_id, email, plan, key_prefix, surface, endpoint, target, filters, result_count) FORMAT TabSeparated\n" <>
          row(meta)
      )
    end)

    :ok
  end

  @doc "The TSV row for one call. Pure; every value is hostile until escaped."
  def row(meta) do
    [
      tsv(meta[:user_id]),
      tsv(meta[:email]),
      tsv(meta[:plan]),
      tsv(meta[:key_prefix]),
      tsv(meta[:surface]),
      tsv(meta[:endpoint]),
      tsv(meta[:target]),
      meta[:filters] |> encode_filters() |> tsv(),
      to_string(meta[:result_count] || 0)
    ]
    |> Enum.join("\t")
  end

  defp encode_filters(nil), do: ""
  defp encode_filters(f) when map_size(f) == 0, do: ""

  defp encode_filters(f) when is_map(f) do
    case Jason.encode(f) do
      {:ok, json} -> String.slice(json, 0, 500)
      _ -> ""
    end
  end

  defp tsv(nil), do: ""

  defp tsv(v) do
    v
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\t", " ")
    |> String.replace("\n", " ")
    |> String.slice(0, 300)
  end
end
