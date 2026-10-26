defmodule LSWeb.ApiKeyRevealLiveTest do
  @moduledoc """
  The Settings page can show a key again (2026-10-26). Pins the owner's
  flow end to end: create a named key, see it once, click Show later and
  get the same key, click Hide and it is gone from the page.
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  test "create, show, hide", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/users/settings")

    html =
      view
      |> form("form[phx-submit=create_api_key]", %{"name" => "claude-web"})
      |> render_submit()

    # Shown once at creation.
    assert html =~ "Copy this key now"
    [key] = LS.ApiKeys.list_keys(user.id)
    {:ok, plain} = LS.ApiKeys.reveal(key)
    assert html =~ plain

    # Reload: the one-time banner is gone, the key is not on the page.
    {:ok, view, html} = live(conn, ~p"/users/settings")
    refute html =~ plain
    assert html =~ "claude-web"

    # Show brings the same key back.
    html = view |> element("button[phx-click=reveal_api_key][phx-value-id=\"#{key.id}\"]") |> render_click()
    assert html =~ plain

    # Hide removes it.
    html = view |> element("button[phx-click=hide_api_key][phx-value-id=\"#{key.id}\"]") |> render_click()
    refute html =~ plain
  end

  test "a legacy key without a stored plaintext tells the owner to rotate", %{conn: conn, user: user} do
    {:ok, _, key} = LS.ApiKeys.create_key(user, "legacy")
    key |> Ecto.Changeset.change(encrypted_key: nil) |> LS.Repo.update!()

    {:ok, view, _} = live(conn, ~p"/users/settings")
    html = view |> element("button[phx-click=reveal_api_key][phx-value-id=\"#{key.id}\"]") |> render_click()
    assert html =~ "Revoke it and create a new one"
  end
end
