defmodule LSWeb.ApiV1Controller do
  @moduledoc """
  The public read-only API, v1 (data model v2 since 2026-10-01). Seven
  endpoints, deliberately few and consolidated (the MCP tools call the
  same functions):

    * `GET /api/v1/company/:domain`: one company's full record, every
      product column under its own name, plus its last 20 changes
    * `GET /api/v1/search`         : filtered company search, one page
    * `GET /api/v1/count`          : how many match, free (2026-10-27)
    * `GET /api/v1/query`          : the analysis read: total, group_by,
      chosen fields, up to 500 rows (2026-10-27, was MCP-only)
    * `GET /api/v1/changes`        : the change feed (tech added or removed,
      hiring started, revenue band moved, website down ...)
    * `GET /api/v1/technologies`   : tech directory with counts
    * `GET /api/v1/stats`          : live dataset numbers

  The filters are `LS.Query`, the same names as the dashboard and the
  CSV. Contact emails are the paid field: free keys get `has_contact` +
  `email_count`, paid plans get the addresses. Usage is recorded only on
  success (2xx), in rows delivered (a company is one row, a page is its
  rows, a count is free), and off the request path (SQLite counter +
  Umami event + ClickHouse audit row, all async).
  """

  use LSWeb, :controller
  alias LS.{ApiData, Plans}
  alias LSWeb.Plugs.ApiAuth

  @paid Plans.paid_plans()

  def company(conn, %{"domain" => domain}) do
    cond do
      not valid_domain?(domain) ->
        ApiAuth.problem(conn, 400, "Invalid domain",
          "The 'domain' path segment must be a bare domain like 'gymshark.com' (no scheme, no path).")

      record = ApiData.company(domain) ->
        track(conn, "api_company", %{endpoint: "company", target: String.downcase(domain), result_count: 1}, 1)
        json(conn, %{data: gate_emails(record, conn.assigns.api_plan)})

      true ->
        ApiAuth.problem(conn, 404, "Domain not found",
          "'#{String.slice(domain, 0, 100)}' is not in the dataset yet. New domains are discovered within hours of getting a TLS certificate; check back or verify the spelling.")
    end
  end

  def search(conn, params) do
    case ApiData.search(params, max_page: Plans.per_page(conn.assigns.api_plan)) do
      {:ok, rows, applied} ->
        track(conn, "api_search", %{endpoint: "search", filters: applied.filters, result_count: length(rows)}, length(rows))

        json(conn, %{
          data: rows,
          count: length(rows),
          total: applied.total,
          limit: applied.limit,
          offset: applied.offset,
          sort: applied.sort,
          filters: applied.filters,
          filters_ignored: applied.ignored,
          filters_accepted: ApiData.search_filters()
        })

      {:error, _} ->
        unavailable(conn, "Search")
    end
  end

  # Free: an agent that counts before it pulls stays inside its rows, and a
  # buyer sees the size of a segment before paying for it.
  def count(conn, params) do
    case ApiData.count(params) do
      {:ok, result} ->
        track(conn, "api_count", %{endpoint: "count", filters: result.filters, result_count: result.total}, 0)

        json(conn, %{
          total: result.total,
          total_note: result.total_note,
          filters: result.filters,
          filters_ignored: result.ignored,
          filters_accepted: ApiData.search_filters()
        })

      {:error, _} ->
        unavailable(conn, "Count")
    end
  end

  def query(conn, params) do
    case ApiData.query(params, max_rows: Plans.query_max(conn.assigns.api_plan)) do
      {:ok, result} ->
        n = length(result.rows)
        track(conn, "api_query", %{endpoint: "query", filters: result.applied.filters, result_count: n}, n)

        json(conn, %{
          data: result.rows,
          count: n,
          total: result.total,
          total_note: result.total_note,
          groups: result.groups,
          applied: result.applied
        })

      {:error, _} ->
        ApiAuth.problem(conn, 503, "Query failed or exceeded its ten-second budget",
          "Narrow the filters or drop group_by, then retry with backoff.")
    end
  end

  def changes(conn, params) do
    case ApiData.changes(params) do
      {:ok, rows, applied} ->
        track(conn, "api_changes", %{endpoint: "changes", filters: Map.take(params, ApiData.changes_filters()), result_count: length(rows)}, length(rows))

        json(conn, %{
          data: LSWeb.McpController.gate_changes(rows, conn.assigns.api_plan),
          count: length(rows),
          limit: applied.limit,
          offset: applied.offset,
          period: applied.period,
          filters_accepted: ApiData.changes_filters()
        })

      {:error, _} ->
        unavailable(conn, "Changes")
    end
  end

  def technologies(conn, _params) do
    track(conn, "api_technologies", %{endpoint: "technologies"}, 0)
    json(conn, %{data: ApiData.technologies()})
  end

  def stats(conn, _params) do
    track(conn, "api_stats", %{endpoint: "stats"}, 0)
    json(conn, %{data: ApiData.stats()})
  end

  defp unavailable(conn, what) do
    ApiAuth.problem(conn, 503, "#{what} temporarily unavailable",
      "The datastore did not answer in time. Retry with backoff; status page: https://listsignal.com.")
  end

  # ── plan gating ───────────────────────────────────────────────────────────

  # The one place the email rule lives. Free tier learns contactability
  # (enough to score a lead) but the addresses are what the plans sell.
  defp gate_emails(record, plan) when plan in @paid, do: record

  defp gate_emails(record, _free) do
    emails = record[:http_emails] || record[:emails] || []

    record
    |> Map.put(:email_count, length(emails))
    |> Map.put(:http_emails, :gated)
    |> Map.put(:http_phone, :gated)
    |> Map.put(:emails_note, "Contact emails and phone require a paid plan: https://listsignal.com/pricing")
  end

  defp valid_domain?(d) when is_binary(d),
    do: byte_size(d) < 254 and Regex.match?(~r/^[a-z0-9.-]+\.[a-z]{2,}$/i, String.trim(d))

  defp valid_domain?(_), do: false

  # Success-only, fully async: SQLite monthly counter (in rows), server-side
  # Umami event, and the ClickHouse audit row (who/when/how/what was read).
  # None of the three can slow or fail the response.
  defp track(conn, event, meta, rows) do
    LS.ApiKeys.record_usage_async(conn.assigns.api_key.id, rows)
    LS.Umami.track_async(event, %{plan: conn.assigns.api_plan, endpoint: meta[:endpoint]})

    LS.ApiAudit.log_async(
      Map.merge(meta, %{
        user_id: conn.assigns.api_user.id,
        email: conn.assigns.api_user.email,
        plan: conn.assigns.api_plan,
        key_prefix: conn.assigns.api_key.prefix,
        surface: "rest"
      })
    )

    conn
  end
end
