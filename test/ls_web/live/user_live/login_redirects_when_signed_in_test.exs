defmodule LSWeb.UserLive.LoginRedirectsWhenSignedInTest do
  @moduledoc """
  Owner's call, 2026-09-15. A login page shown to someone already logged in is
  a dead end: there is nothing useful to do on it, and this one actively
  trapped him. His browser held a customer's session, the email field carried
  that customer's address, and the page offered no way out — which is what
  "I can't log in as another user" turned out to mean, after two wrong
  diagnoses (a `readonly` attribute, then a server-rendered value LiveView
  kept patching back).

  A signed-in visitor now goes to the dashboard, where the log-out link lives
  (`explorer_live.ex`). Log out there, come back, and the page works.

  The single exception is `:require_sudo_mode` bouncing someone here to
  re-authenticate. It marks that with `?reauth=1`, because the alternative —
  inferring intent from flash text — breaks the moment anyone rewords the
  message.
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  test "a signed-in visitor is sent to the dashboard, not held on the form", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/users/log-in")
  end

  test "the dashboard it lands on is the page that can log you out", %{conn: conn} do
    # Redirecting into another dead end would be the same bug again.
    assert File.read!("lib/ls_web/live/explorer_live.ex") =~ ~s(~p"/users/log-out"),
           "the redirect target must offer a log-out, or the trap just moves"
  end

  test "re-authentication still reaches the form, because it says so explicitly" do
    assert File.read!("lib/ls_web/user_auth.ex") =~ ~s(~p"/users/log-in?reauth=1"),
           "require_sudo_mode must mark its bounce, or signed-in re-auth is impossible"
  end

  test "?reauth=1 shows the form to a signed-in user", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/users/log-in?reauth=1")

    assert html =~ "Re-authenticate"
    assert html =~ user.email, "they should see which account they are confirming"
  end

  test "a signed-out visitor still gets the form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    assert html =~ "Log in"
    assert html =~ "Sign up"
  end

  test "after logging out, the login page is reachable again", %{conn: conn} do
    conn = log_in_user(conn, user_fixture())
    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/users/log-in")

    conn = delete(conn, ~p"/users/log-out")
    assert redirected_to(conn) == ~p"/"

    {:ok, _lv, html} = live(conn, ~p"/users/log-in")
    assert html =~ "Sign up", "logging out must restore the normal login page"
  end
end
