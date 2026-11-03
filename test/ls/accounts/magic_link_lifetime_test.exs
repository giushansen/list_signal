defmodule LS.Accounts.MagicLinkLifetimeTest do
  @moduledoc """
  2026-11-03: a signup opened the confirmation mail 22 minutes after it was
  sent and was told "Magic link is invalid or it has expired". The limit
  was the generator's 15 minutes; the account stayed unconfirmed and the
  person wrote in to ask what was wrong. A day is the window a signup mail
  is realistically read in, and the link is single use, so the longer
  window costs nothing a mailbox reader could not already do.
  """
  use LSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import LS.AccountsFixtures

  alias LS.Accounts
  alias LS.Accounts.UserToken
  alias LS.Repo

  defp age_token(minutes) do
    at = NaiveDateTime.utc_now() |> NaiveDateTime.add(-minutes * 60, :second)
    {1, nil} = Repo.update_all(UserToken, set: [inserted_at: at])
  end

  defp confirmation_token(user) do
    extract_user_token(fn url -> Accounts.deliver_login_instructions(user, url) end)
  end

  test "a confirmation link read 22 minutes after sending still confirms the account" do
    user = unconfirmed_user_fixture()
    token = confirmation_token(user)
    age_token(22)

    assert {:ok, {confirmed, _}} = Accounts.login_user_by_magic_link(token)
    assert confirmed.confirmed_at
  end

  test "a link read the same evening, eleven hours later, still works" do
    user = unconfirmed_user_fixture()
    token = confirmation_token(user)
    age_token(11 * 60)

    assert Accounts.get_user_by_magic_link_token(token).id == user.id
  end

  test "a link older than a day is refused" do
    user = unconfirmed_user_fixture()
    token = confirmation_token(user)
    age_token(UserToken.magic_link_validity_in_minutes() + 1)

    refute Accounts.get_user_by_magic_link_token(token)
  end

  test "a link is single use, however young" do
    user = unconfirmed_user_fixture()
    token = confirmation_token(user)

    assert {:ok, _} = Accounts.login_user_by_magic_link(token)
    refute Accounts.get_user_by_magic_link_token(token)
  end

  test "an expired link lands on the login form with the address filled in", %{conn: conn} do
    user = unconfirmed_user_fixture()
    token = confirmation_token(user)
    age_token(UserToken.magic_link_validity_in_minutes() + 1)

    {:ok, _lv, html} =
      live(conn, ~p"/users/log-in/#{token}")
      |> follow_redirect(conn, ~p"/users/log-in")

    assert html =~ "Send yourself a fresh one below"
    assert html =~ user.email
  end

  test "a garbage token prefills nothing and says the link is invalid", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/users/log-in/not-a-token")
      |> follow_redirect(conn, ~p"/users/log-in")

    assert html =~ "Magic link is invalid or it has expired"
    assert UserToken.magic_link_sent_to("not-a-token") == nil
    assert UserToken.magic_link_sent_to("") == nil
  end
end
