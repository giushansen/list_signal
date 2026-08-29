defmodule LSWeb.ApiV1Controller do
  @moduledoc """
  The public read-only API, v1. Four endpoints, deliberately few and
  consolidated (the MCP tools call the same functions):

    * `GET /api/v1/company/:domain`: one company's full record
    * `GET /api/v1/search`         : filtered company search
    * `GET /api/v1/technologies`   : tech directory with counts
    * `GET /api/v1/stats`          : live dataset numbers

  Contact emails are the paid field: free keys get `has_contact` +
  `email_count`, paid plans get the addresses. Usage is recorded only on
  success (2xx): an agent must never pay for a miss: and off the request
  path (SQLite counter + Umami event, both async).
  """

  use LSWeb, :controller
  alias LS.ApiData
  alias LSWeb.Plugs.ApiAuth

  def company(conn, %{"domain" => domain}) do
    cond do
      not valid_domain?(domain) ->
        ApiAuth.problem(conn, 400, "Invalid domain",
          "The 'domain' path segment must be a bare domain like 'gymshark.com' (no scheme, no path).")

      record = ApiData.company(domain) ->
        track(conn, "api_company")
        json(conn, %{data: gate_emails(record, conn.assigns.api_plan)})

      true ->
        ApiAuth.problem(conn, 404, "Domain not found",
          "'#{String.slice(domain, 0, 100)}' is not in the dataset yet. New domains are discovered within hours of getting a TLS certificate; check back or verify the spelling.")
    end
  end

  def search(conn, params) do
    case ApiData.search(params) do
      {:ok, rows, applied} ->
        track(conn, "api_search")

        json(conn, %{
          data: rows,
          count: length(rows),
          limit: applied.limit,
          offset: applied.offset,
          filters_accepted: ~w(tech app country business_model revenue hiring limit offset)
        })

      {:error, _} ->
        ApiAuth.problem(conn, 503, "Search temporarily unavailable",
          "The datastore did not answer in time. Retry with backoff; status page: https://listsignal.com.")
    end
  end

  def technologies(conn, _params) do
    track(conn, "api_technologies")
    json(conn, %{data: ApiData.technologies()})
  end

  def stats(conn, _params) do
    track(conn, "api_stats")
    json(conn, %{data: ApiData.stats()})
  end

  # ── plan gating ───────────────────────────────────────────────────────────

  # The one place the email rule lives. Free tier learns contactability
  # (enough to score a lead) but the addresses are what the plans sell.
  defp gate_emails(record, plan) when plan in ["starter", "pro"], do: record

  defp gate_emails(record, _free) do
    record
    |> Map.put(:email_count, length(record.emails))
    |> Map.put(:emails, :gated)
    |> Map.put(:emails_note, "Contact emails require a paid plan: https://listsignal.com/pricing")
  end

  defp valid_domain?(d) when is_binary(d),
    do: byte_size(d) < 254 and Regex.match?(~r/^[a-z0-9.-]+\.[a-z]{2,}$/i, String.trim(d))

  defp valid_domain?(_), do: false

  # Success-only, fully async: the SQLite monthly counter and a server-side
  # Umami event. Neither can slow or fail the response.
  defp track(conn, event) do
    LS.ApiKeys.record_usage_async(conn.assigns.api_key.id)
    LS.Umami.track_async(event, %{plan: conn.assigns.api_plan})
    conn
  end
end
