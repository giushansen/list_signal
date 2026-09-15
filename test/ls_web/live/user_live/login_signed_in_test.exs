defmodule LSWeb.UserLive.LoginSignedInTest do
  @moduledoc """
  2026-09-15: the owner opened /users/log-in in a browser that still held a
  session and found the email field locked, with only the password field
  editable and no way to switch accounts. The generated page had made the
  email read-only whenever a session existed. These pin the fix: the field
  is always editable, and a signed-in visitor is told who they are and how
  to leave.
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  defp email_inputs(html), do: Regex.scan(~r/<input[^>]*name="user\[email\]"[^>]*>/, html) |> List.flatten()

  test "a signed-out visitor can type an email in both forms", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    inputs = email_inputs(html)
    assert length(inputs) == 2
    refute Enum.any?(inputs, &(&1 =~ "readonly")), "email field must never be read-only"
  end

  test "a signed-in visitor is told who they are and can leave, and the email stays editable", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/users/log-in")

    assert html =~ "You are signed in as"
    assert html =~ user.email
    assert html =~ ~p"/dashboard"
    assert html =~ ~p"/users/log-out"

    inputs = email_inputs(html)
    assert length(inputs) == 2
    refute Enum.any?(inputs, &(&1 =~ "readonly")), "a held session must not lock the email field"
  end

  test "a signed-in visitor can log in as another account from the same page", %{conn: conn} do
    first = user_fixture()
    other = user_fixture() |> set_password()
    conn = log_in_user(conn, first)

    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    form =
      form(lv, "#login_form_password",
        user: %{email: other.email, password: valid_user_password(), remember_me: true}
      )

    conn = submit_form(form, conn)

    assert redirected_to(conn) == ~p"/dashboard"
    assert {%LS.Accounts.User{id: id}, _} = LS.Accounts.get_user_by_session_token(get_session(conn, :user_token))
    assert id == other.id
  end
end
