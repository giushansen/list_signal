defmodule LSWeb.DashboardV2BrowseTest do
  @moduledoc """
  A customer's walk through the v2 dashboard against a real ClickHouse
  (2026-10-01): open the explorer, wait for rows, expand one business, read
  its v2 fields, switch to Signals, wait for change rows, and download both
  CSVs as a paying user. Skipped when no ClickHouse answers on
  127.0.0.1:8123, like the data-contract suite, so `mix test` stays green on
  a laptop without the harness.

  This is the test the owner asked for in words: "browse the dashboard and
  the signals and export some to test the CSV is correct and usable".
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  alias LS.Clickhouse

  @moduletag timeout: 120_000

  setup_all do
    case Clickhouse.query_raw("SELECT count() FROM businesses WHERE notEmpty(http_tech)", 5_000) do
      {:ok, [[n]]} when n not in [0, "0"] ->
        :ok

      _ ->
        IO.puts("\n[dashboard v2 browse] skipped: no ClickHouse with v2 businesses on 127.0.0.1:8123")
        :skip
    end
  end

  setup %{conn: conn} do
    user =
      user_fixture()
      |> Ecto.Changeset.change(%{plan: "pro", stripe_subscription_id: "manual_override"})
      |> LS.Repo.update!()

    %{conn: log_in_user(conn, user), user: user}
  end

  defp wait_rows(lv, selector, tries \\ 40) do
    html = render(lv)

    cond do
      html =~ selector -> html
      tries == 0 -> flunk("no rows rendered for #{selector}")
      true ->
        Process.sleep(250)
        wait_rows(lv, selector, tries - 1)
    end
  end

  test "explorer: rows, a detail panel in v2 names, and the CSV", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/dashboard")
    html = wait_rows(lv, "phx-value-domain=")

    [_, domain] = Regex.run(~r/phx-value-domain="([^"]+)"/, html)
    assert domain != ""

    lv |> element(~s(tr[phx-value-domain="#{domain}"])) |> render_click()
    detail = wait_rows(lv, "Tech Stack")
    assert detail =~ domain
    assert detail =~ "Business Model"
    assert detail =~ "Mail Provider" or detail =~ "DNS"

    conn = get(conn, ~p"/dashboard/export?tech=Shopify")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
    [header | rows] = conn.resp_body |> String.split("\n", trim: true)
    columns = String.split(header, ",")
    assert columns == LS.Schema.Columns.export_columns()
    assert rows != [], "the Shopify export must carry rows"

    # Every row has as many cells as the header (quoted cells can hold commas).
    for row <- Enum.take(rows, 20) do
      assert length(csv_cells(row)) == length(columns), "row has a different cell count: #{String.slice(row, 0, 120)}"
    end

    tech_idx = Enum.find_index(columns, &(&1 == "http_tech"))
    assert Enum.all?(Enum.take(rows, 20), fn r -> r |> csv_cells() |> Enum.at(tech_idx) |> String.contains?("Shopify") end)
  end

  test "signals: rows read as sentences, filters apply, and the CSV", %{conn: conn} do
    {:ok, lv, _} = live(conn, ~p"/dashboard/signals?period=90d")
    html = wait_rows(lv, "signals-table")

    if html =~ "No changes match" do
      IO.puts("\n[dashboard v2 browse] no changes in the last 90 days on this harness; sentence checks skipped")
    else
      assert html =~ ~r/(added|removed|changed|started hiring|website)/
    end

    lv
    |> form("#signals_form", %{"field" => "http_tech", "change" => "added", "period" => "90d"})
    |> render_change()

    conn = get(conn, ~p"/dashboard/signals/export?field=http_tech&change=added&period=90d")
    assert conn.status == 200
    [header | rows] = conn.resp_body |> String.split("\n", trim: true)
    assert String.split(header, ",") == LS.Signals.export_columns()

    for row <- Enum.take(rows, 20) do
      cells = csv_cells(row)
      assert length(cells) == length(LS.Signals.export_columns())
      assert Enum.at(cells, 1) == "http_tech"
      assert Enum.at(cells, 2) == "added"
      assert List.last(cells) =~ " added"
    end
  end

  # A small CSV cell splitter that honours double quotes, enough for the
  # files we write (RFC 4180 quoting of comma, quote and newline).
  defp csv_cells(line) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], "", false}, fn
      "\"", {cells, cur, inq} -> {cells, cur, not inq}
      ",", {cells, cur, false} -> {[cur | cells], "", false}
      ch, {cells, cur, inq} -> {cells, cur <> ch, inq}
    end)
    |> then(fn {cells, cur, _} -> Enum.reverse([cur | cells]) end)
  end
end
