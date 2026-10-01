defmodule LSWeb.ExportController do
  @moduledoc "CSV export of explorer result sets (plan-gated row limits)."
  use LSWeb, :controller

  alias LS.{Accounts, Explorer, Signals}
  alias LS.Accounts.User

  @explorer_filter_keys ~w(tech shopify_app country business_model industry revenue employees language domain_search freshness discovered dns_email_provider has_email hiring has_pricing has_catalog min_products max_products min_price_avg max_price_avg min_seo_score max_seo_score min_new_products_30d ats_platform)

  def csv(conn, params) do
    filters = Enum.map(@explorer_filter_keys, fn key -> {String.to_atom(key), params[key] || ""} end)
    export(conn, "csv_export", "listsignal_export.csv", ~p"/dashboard", filters, &Explorer.export_rows/2)
  end

  @doc "The Signals tab's CSV: one change per row, same quota and cap as the company export."
  def signals_csv(conn, params) do
    filters = Map.new(Signals.filter_keys(), fn key -> {key, params[to_string(key)] || ""} end)
    filters = if filters.period == "", do: %{filters | period: "7d"}, else: filters
    export(conn, "signals_csv_export", "listsignal_signals.csv", ~p"/dashboard/signals", filters, &Signals.export_rows/2)
  end

  defp export(conn, event, filename, back, filters, rows_fun) do
    user = conn.assigns.current_scope.user

    if Accounts.can_export?(user) do
      plan = User.effective_plan(user)
      limit = Accounts.exports_remaining(user)

      case rows_fun.(filters, min(limit, export_cap(plan))) do
        {:ok, {columns, rows}} ->
          Accounts.increment_exports(user, length(rows))

          # Evidence, not telemetry: a dispute is decided on whether we can
          # show the customer received the data they paid for.
          LS.Audit.record_from_conn(conn, event, %{
            user_id: user.id,
            email: user.email,
            metadata: %{rows: length(rows), plan: plan, filters: inspect(filters)}
          })

          conn
          |> put_resp_content_type("text/csv")
          |> put_resp_header("content-disposition", "attachment; filename=\"#{filename}\"")
          |> send_resp(200, build_csv(columns, rows))

        _ ->
          conn
          |> put_flash(:error, "Export failed. Please try again.")
          |> redirect(to: back)
      end
    else
      conn
      |> put_flash(:error, "CSV export is not available on your plan or you've reached your monthly limit.")
      |> redirect(to: back)
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

  # Lists (tech stack, emails, subdomains) flatten to one pipe-separated cell:
  # the file stays one row per company and opens in any spreadsheet.
  defp csv_escape(val) when is_list(val), do: val |> Enum.map(&to_string/1) |> Enum.join("|") |> csv_escape()
  defp csv_escape(val), do: to_string(val)
end
