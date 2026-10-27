defmodule LS.RowsMeteringTest do
  @moduledoc """
  Rows are the unit (2026-10-27). Before this the API metered calls and
  the CSV metered rows, in two counters that never met: Pro sold 50,000
  CSV rows while its API allowed 25,000 calls of 100 rows. And the CSV
  counter never reset: `exports_reset_at` existed since the first
  migration and nothing read it, so a customer who spent 5,000 rows in
  June was still at 5,000 in October. These tests pin the one pool, the
  per-call cost, the free calls and the monthly reset.
  """
  use LSWeb.ConnCase

  import LS.AccountsFixtures
  alias LS.{Accounts, ApiKeys}

  setup do
    user = user_fixture()
    {:ok, token, key} = ApiKeys.create_key(user, "test")
    %{user: user, key: key, token: token}
  end

  test "a call costs the rows it returns; a count costs nothing; a month written before rows counts its calls", %{key: key, user: user} do
    ApiKeys.record_usage(key.id, 25)
    ApiKeys.record_usage(key.id, 0)
    ApiKeys.record_usage(key.id)
    assert ApiKeys.usage_this_month(key.id) == 3
    assert ApiKeys.rows_this_month(key.id) == 26
    assert ApiKeys.user_usage_this_month(user.id) == 26

    # A usage row from before the migration has rows = nil and counts calls.
    {:ok, _, legacy} = ApiKeys.create_key(user, "legacy")
    %ApiKeys.ApiUsage{api_key_id: legacy.id, period: ApiKeys.current_period(), calls: 40}
    |> LS.Repo.insert!()

    assert ApiKeys.user_usage_this_month(user.id) == 66
  end

  test "the CSV and the API spend one pool", %{key: key, user: user} do
    assert Accounts.rows_remaining(user) == 1_000
    ApiKeys.record_usage(key.id, 300)
    {:ok, user} = Accounts.increment_exports(user, 200)
    assert Accounts.rows_used_this_month(user) == 500
    assert Accounts.rows_remaining(user) == 500
    assert Accounts.can_export?(user)

    {:ok, user} = Accounts.increment_exports(user, 500)
    assert Accounts.rows_remaining(user) == 0
    refute Accounts.can_export?(user)
  end

  test "the CSV counter belongs to its month and restarts on the next", %{user: user} do
    last_month = DateTime.utc_now() |> DateTime.add(-40, :day)

    user =
      user
      |> Ecto.Changeset.change(exports_used_this_month: 900, exports_reset_at: DateTime.truncate(last_month, :second))
      |> LS.Repo.update!()

    assert Accounts.rows_used_this_month(user) == 0, "last month's rows do not count this month"
    {:ok, user} = Accounts.increment_exports(user, 10)
    assert user.exports_used_this_month == 10
    assert Accounts.rows_used_this_month(user) == 10
  end

  test "a spent month refuses rows but still answers counts and stats", %{conn: conn, key: key, token: token} do
    ApiKeys.record_usage(key.id, 1_000)

    refused = conn |> put_req_header("authorization", "Bearer #{token}") |> get(~p"/api/v1/search?country=US")
    assert refused.status == 403
    assert Jason.decode!(refused.resp_body)["detail"] =~ "rows a month"

    stats = conn |> put_req_header("authorization", "Bearer #{token}") |> get(~p"/api/v1/stats")
    assert stats.status == 200

    # The MCP handshake and the count tool are free too; a search is not.
    mcp = fn body ->
      conn |> put_req_header("authorization", "Bearer #{token}") |> put_req_header("content-type", "application/json") |> post(~p"/mcp", Jason.encode!(body))
    end

    assert mcp.(%{jsonrpc: "2.0", id: 1, method: "tools/list"}).status == 200
    assert mcp.(%{jsonrpc: "2.0", id: 2, method: "tools/call", params: %{name: "listsignal_dataset_stats", arguments: %{}}}).status == 200
    assert mcp.(%{jsonrpc: "2.0", id: 3, method: "tools/call", params: %{name: "listsignal_search_companies", arguments: %{country: "US"}}}).status == 403
  end

  test "free_call? names exactly the calls that cannot cost rows" do
    free = fn path, body -> LSWeb.Plugs.ApiAuth.free_call?(%Plug.Conn{path_info: path, body_params: body}) end
    assert free.(~w(api v1 count), %{})
    assert free.(~w(api v1 stats), %{})
    refute free.(~w(api v1 search), %{})
    refute free.(~w(api v1 company gymshark.com), %{})
    assert free.(["mcp"], %{"method" => "initialize"})
    assert free.(["mcp"], %{"method" => "tools/call", "params" => %{"name" => "listsignal_count"}})
    refute free.(["mcp"], %{"method" => "tools/call", "params" => %{"name" => "listsignal_query"}})
    refute free.(["mcp"], %{})
  end

  test "the rate limit is the plan's searches a minute, the same number as the dashboard" do
    for plan <- LS.Plans.names() do
      assert ApiKeys.rate_per_min(plan) == LS.Plans.per_min(plan)
    end

    assert LS.RateLimiter.stats("nobody", "scale").limit == 300
  end

  test "an email-added change row never carries the address on a plan without addresses" do
    rows = [%{field: "http_emails", change: "added", value: "sarah@a.com", prev_value: "", summary: "sarah@a.com added"}, %{field: "http_tech", change: "added", value: "Klaviyo", prev_value: "", summary: "Klaviyo added"}]
    [gated, kept] = LSWeb.McpController.gate_changes(rows, "free")
    refute gated.value =~ "@"
    refute gated.summary =~ "@"
    assert kept.value == "Klaviyo"
    assert LSWeb.McpController.gate_changes(rows, "pro") == rows

    columns = ~w(domain field change value prev_value changed_at summary)
    csv = [["a.com", "http_emails", "added", "sarah@a.com", "", "2026-10-27 10:00:00", "sarah@a.com added"]]
    [[_, _, _, v, _, _, sum]] = LSWeb.ExportController.gate_contacts(columns, csv, "free")
    assert v == "" and sum == ""
  end

  test "a free CSV keeps the columns and blanks the addresses; a paid one keeps them" do
    columns = ~w(domain http_emails http_phone http_emails_evidence estimated_revenue)
    rows = [["a.com", "x@a.com|y@a.com", "+1", "homepage", "$1M-$10M"]]
    assert LSWeb.ExportController.gate_contacts(columns, rows, "free") == [["a.com", "", "", "", "$1M-$10M"]]
    assert LSWeb.ExportController.gate_contacts(columns, rows, "starter") == rows
  end
end
