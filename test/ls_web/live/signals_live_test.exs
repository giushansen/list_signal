defmodule LSWeb.SignalsLiveTest do
  @moduledoc """
  The Signals tab (data model v2, 2026-10-01): a signed-in customer can open
  it from the dashboard, filter it, and the export is gated like the company
  export. The queries themselves are pinned in `LS.SignalsTest`; here the
  LiveView has to mount and route without a ClickHouse server.
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "the dashboard shows both tabs and the Signals tab mounts", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")
    assert html =~ "Signals"
    assert html =~ ~s(href="/dashboard/signals")

    {:ok, _lv, html} = live(conn, ~p"/dashboard/signals")
    assert html =~ "Any field"
    assert html =~ "Last 7d"
    assert html =~ "Businesses"
  end

  test "filters round-trip through the URL so a reconnect restores them", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/signals?field=http_tech&change=added&value=Klaviyo&period=30d")
    html = render(lv)
    assert html =~ ~s(value="Klaviyo")
    assert html =~ ~s(<option value="30d" selected)
    assert html =~ ~s(<option value="http_tech" selected)
  end

  test "changing a filter patches the URL and resets to page 1", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/signals?page=3")

    lv
    |> form("#signals_form", %{"field" => "hr_job_count", "change" => "started", "period" => "24h"})
    |> render_change()

    assert_patch(lv, "/dashboard/signals?change=started&field=hr_job_count&period=24h")
  end

  test "a free user sees no download link and the export route refuses", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard/signals")
    refute html =~ "/dashboard/signals/export"

    conn = get(conn, ~p"/dashboard/signals/export?field=http_tech")
    assert redirected_to(conn) == ~p"/dashboard/signals"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not available on your plan"
  end

  test "the tracked fields offered are exactly the spec's tracked columns", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard/signals")

    for {name, _rule, _type} <- LS.Schema.Columns.tracked() do
      assert html =~ ~s(<option value="#{name}"), "#{name} not offered"
    end
  end
end
