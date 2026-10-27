defmodule LSWeb.ExportController do
  @moduledoc """
  CSV export of explorer result sets. The filters are `LS.Query`, the same
  names as the dashboard URL, the API and the MCP, so the export link is
  the search. Rows are metered against the plan's monthly pool
  (`LS.Accounts.rows_remaining/1`), the same pool the API spends. Free
  exports too, with the contact columns blanked: 1,000 rows a month of
  the dataset without addresses is exactly what a free API key gets, and
  a file is how a buyer shows the data to a colleague.
  """
  use LSWeb, :controller

  alias LS.{Accounts, Explorer, Plans, Signals}
  alias LS.Accounts.User

  # The columns a plan without emails does not get in the file.
  @contact_columns ~w(http_emails http_emails_evidence http_phone)

  def csv(conn, params) do
    {filters, _ignored} = LS.Query.parse(params)
    export(conn, "csv_export", "listsignal_export.csv", ~p"/dashboard", Enum.to_list(filters), &Explorer.export_rows/2)
  end

  @doc "The Signals tab's CSV: one change per row, same quota and cap as the company export."
  def signals_csv(conn, params) do
    filters = Map.new(Signals.filter_keys(), fn key -> {key, params[to_string(key)] || ""} end)
    filters = if filters.period == "", do: %{filters | period: "7d"}, else: filters
    export(conn, "signals_csv_export", "listsignal_signals.csv", ~p"/dashboard/signals", filters, &Signals.export_rows/2)
  end

  defp export(conn, event, filename, back, filters, rows_fun) do
    user = conn.assigns.current_scope.user
    plan = User.effective_plan(user)

    if Accounts.can_export?(user) do
      limit = Accounts.rows_remaining(user)

      case rows_fun.(filters, min(limit, Plans.file_cap(plan))) do
        {:ok, {columns, rows}} ->
          Accounts.increment_exports(user, length(rows))
          rows = gate_contacts(columns, rows, plan)

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
      |> put_flash(:error, "You have used this month's #{Plans.fmt(Plans.rows(plan))} rows. The counter resets on the 1st; upgrade for more.")
      |> redirect(to: back)
    end
  end

  # The addresses are what the paid plans sell. A free file keeps the
  # columns (same header on every plan, so a CRM import works) and blanks
  # the cells.
  # The Signals file is a list of changes, and an "email added" change
  # carries the address in its value column: blanked too.
  @doc false
  def gate_contacts(columns, rows, plan) do
    if Plans.emails?(plan) do
      rows
    else
      index = columns |> Enum.with_index() |> Map.new()
      hidden = @contact_columns |> Enum.map(&index[&1]) |> Enum.reject(&is_nil/1)
      {field_i, value_i, prev_i, summary_i} = {index["field"], index["value"], index["prev_value"], index["summary"]}

      Enum.map(rows, fn row ->
        row = Enum.reduce(hidden, row, fn i, r -> List.replace_at(r, i, "") end)

        if field_i && value_i && Enum.at(row, field_i) == "http_emails" do
          [value_i, prev_i, summary_i]
          |> Enum.reject(&is_nil/1)
          |> Enum.reduce(row, fn i, r -> List.replace_at(r, i, "") end)
        else
          row
        end
      end)
    end
  end

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
