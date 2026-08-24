defmodule LS.Accounts.UserNotifier do
  @moduledoc "Builds and delivers account emails (magic-link login, confirmations) via `LS.Mailer`."
  import Swoosh.Email

  alias LS.Mailer
  alias LS.Accounts.User

  # Plain text on purpose. These carry login and confirmation links, so the
  # only thing that matters is that the link always works: HTML would add a
  # rendering failure mode for no benefit, and most clients auto-link a bare
  # URL anyway.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(LS.Ops.Mail.from())
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(
      user.email,
      "Confirm your new email address",
      """
      Hi,

      Confirm your new email address:
      #{url}

      If you did not ask to change it, you can ignore this email.

      Will
      ListSignal
      """
    )
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(
      user.email,
      "Your ListSignal login link",
      """
      Hi,

      Log in to ListSignal:
      #{url}

      If you did not ask for it, you can ignore this email.

      Will
      ListSignal
      """
    )
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(
      user.email,
      "Confirm your ListSignal account",
      """
      Hi,

      You're one click away — confirm here:
      #{url}

      Working on a list? Reply and I'll build it with you.

      Will
      ListSignal
      """
    )
  end
end
