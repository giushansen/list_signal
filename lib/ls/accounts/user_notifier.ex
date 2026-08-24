defmodule LS.Accounts.UserNotifier do
  @moduledoc "Builds and delivers account emails (magic-link login, confirmations) via `LS.Mailer`."
  import Swoosh.Email
  import LS.EmailLayout, only: [shell: 1, p: 1, cta: 2]

  alias LS.Mailer
  alias LS.Accounts.User

  # Multipart: HTML hides the long signed URL behind a clickable phrase, and
  # the text fallback keeps the raw link so a plain-text client can still log
  # in. An auth email that renders as a dead end is a locked-out customer.
  defp deliver(recipient, subject, body, html) do
    email =
      new()
      |> to(recipient)
      |> from(LS.Ops.Mail.from())
      |> subject(subject)
      |> html_body(html)
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

      Use this link to confirm your new email address: #{url}

      If you did not ask to change it, you can ignore this email.

      Will from ListSignal
      """,
      shell(
        p("Hi,") <>
          cta(url, "Confirm your new email address") <>
          p("If you did not ask to change it, you can ignore this email.") <>
          p("Will from ListSignal")
      )
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

      Here is your login link: #{url}

      If you did not ask for it, you can ignore this email.

      Will from ListSignal
      """,
      shell(
        p("Hi,") <>
          cta(url, "Log in to ListSignal") <>
          p("If you did not ask for it, you can ignore this email.") <>
          p("Will from ListSignal")
      )
    )
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(
      user.email,
      "Confirm your ListSignal account",
      """
      Hi,

      Confirm your account with this link: #{url}

      Once you are in, tell me what list you are trying to build and I can build it with you.

      Will from ListSignal
      """,
      shell(
        p("Hi,") <>
          cta(url, "Confirm your account") <>
          p("Once you are in, tell me what list you are trying to build and I can build it with you.") <>
          p("Will from ListSignal")
      )
    )
  end
end
