defmodule LSWeb.ExportController do
  @moduledoc "CSV export of explorer result sets (plan-gated row limits)."
  use LSWeb, :controller

  alias LS.{Accounts, Explorer}
  alias LS.Accounts.User

  def csv(conn, params) do
    user = conn.assigns.current_scope.user

    if Accounts.can_export?(user) do
      plan = User.effective_plan(user)
      limit = Accounts.exports_remaining(user)

      filters =
        Enum.map(
          ~w(tech country business_model industry revenue employees language domain_search freshness),
          fn key -> {String.to_atom(key), params[key] || ""} end
        )

      case Explorer.export_rows(filters, min(limit, export_cap(plan))) do
        {:ok, {columns, rows}} ->
          Accounts.increment_exports(user, length(rows))

          # Evidence, not telemetry: a dispute is decided on whether we can
          # show the customer received the data they paid for.
          LS.Audit.record_from_conn(conn, "csv_export", %{
            user_id: user.id,
            email: user.email,
            metadata: %{rows: length(rows), plan: plan, filters: inspect(filters)}
          })

          csv_data = build_csv(columns, rows)

          conn
          |> put_resp_content_type("text/csv")
          |> put_resp_header("content-disposition", "attachment; filename=\"listsignal_export.csv\"")
          |> send_resp(200, csv_data)

        _ ->
          conn
          |> put_flash(:error, "Export failed. Please try again.")
          |> redirect(to: ~p"/dashboard")
      end
    else
      conn
      |> put_flash(:error, "CSV export is not available on your plan or you've reached your monthly limit.")
      |> redirect(to: ~p"/dashboard")
    end
  end

  # Rows in ONE file, distinct from the monthly quota in Accounts.export_limit/1.
  # A single CSV past ~25k rows stops being a working list and starts being a
  # database dump: slow to open, impossible to review, and far easier to
  # resell. Users who need more take several files, which is also what makes
  # the monthly quota meaningful.
  defp export_cap("pro"), do: 25_000
  defp export_cap("starter"), do: 2_500
  defp export_cap(_), do: 0

  defp build_csv(columns, rows) do
    header = Enum.join(columns, ",")

    data_rows =
      Enum.map(rows, fn row ->
        Enum.map(row, &csv_escape/1) |> Enum.join(",")
      end)

    Enum.join([header | data_rows], "\n")
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(val) when is_binary(val) do
    if String.contains?(val, [",", "\"", "\n"]) do
      "\"" <> String.replace(val, "\"", "\"\"") <> "\""
    else
      val
    end
  end

  defp csv_escape(val), do: to_string(val)
end
