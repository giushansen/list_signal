defmodule LSWeb.UserLive.LoginEmailNotPinnedTest do
  @moduledoc """
  INCIDENT 2026-09-15, second of three diagnoses. Removing `readonly` from the
  login email field that morning made it editable and still not typeable:
  `mount/3` filled the form from `current_scope.user.email`, so the value was
  server-rendered on every pass. LiveView patches a server-rendered value back
  on any re-render — a reconnect, a flash, any assign change — so whatever was
  typed reverted, and a reload rendered the same address again from the same
  place.

  The owner's browser held a customer's session, so the field showed that
  customer's address and would not accept another. Refreshing did not help,
  because refreshing is what re-rendered it.

  The rule: the email input is prefilled ONLY from the flash, which carries
  back an address someone just typed after a wrong password. Who is signed in
  belongs in the prose, never in the input's value.

  A signed-in visitor is now redirected to the dashboard entirely
  (`login_redirects_when_signed_in_test.exs`), so the only way to see this
  form while holding a session is the `?reauth=1` re-authentication bounce —
  which is exactly where a pinned field would still bite.
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  defp email_inputs(html),
    do: Regex.scan(~r/<input[^>]*name="user\[email\]"[^>]*>/, html) |> List.flatten()

  defp values(html),
    do:
      email_inputs(html)
      |> Enum.map(fn tag ->
        case Regex.run(~r/value="([^"]*)"/, tag) do
          [_, v] -> v
          nil -> ""
        end
      end)

  test "a held session never lands in the email input", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/users/log-in?reauth=1")

    assert length(email_inputs(html)) == 2
    assert values(html) == ["", ""], "the signed-in address must not be welded into the field"
    refute Enum.any?(email_inputs(html), &(&1 =~ "readonly"))
  end

  test "the page still says who is signed in, just not inside the input", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, _lv, html} = live(conn, ~p"/users/log-in?reauth=1")

    assert html =~ "You are signed in as"
    assert html =~ user.email, "the address belongs in the prose"
    refute Enum.any?(email_inputs(html), &(&1 =~ user.email))
  end

  test "a signed-out visitor gets empty fields", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/users/log-in")
    assert values(html) == ["", ""]
  end

  test "a wrong password still returns the address the person typed", %{conn: conn} do
    # The one case the prefill exists for: it must survive, because retyping an
    # address after a typo'd password is the whole point of the flash.
    user = user_fixture() |> set_password()

    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    form =
      form(lv, "#login_form_password", user: %{email: user.email, password: "wrong-password"})

    conn = submit_form(form, conn)
    assert redirected_to(conn) == ~p"/users/log-in"

    {:ok, _lv, html} = live(conn, ~p"/users/log-in")
    assert values(html) == [user.email, user.email]
  end

  test "re-authenticating as a different account still works from that form", %{conn: conn} do
    # With an empty field the person can type any address, which is what the
    # pinned value prevented.
    held = user_fixture()
    other = user_fixture() |> set_password()
    conn = log_in_user(conn, held)

    {:ok, lv, _html} = live(conn, ~p"/users/log-in?reauth=1")

    form =
      form(lv, "#login_form_password",
        user: %{email: other.email, password: valid_user_password(), remember_me: true}
      )

    conn = submit_form(form, conn)

    assert redirected_to(conn) == ~p"/dashboard"

    assert {%LS.Accounts.User{id: id}, _} =
             LS.Accounts.get_user_by_session_token(get_session(conn, :user_token))

    assert id == other.id
  end
end
