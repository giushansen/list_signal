defmodule LS.Feedback do
  @moduledoc """
  Data-quality feedback from the dashboard, straight to the owner's inbox.

  The report is sent even when the text is empty: the domain plus the
  reporter's address is already actionable — the owner can look at the record
  and reply to the customer — and requiring prose loses exactly the users who
  would otherwise click once and move on.
  """

  import Swoosh.Email
  require Logger

  @to "will@listsignal.com"

  @doc """
  Deliver a feedback report. Never raises and runs the send off-process:
  a mail hiccup must neither crash the LiveView nor add SMTP latency to a
  button click. Also writes an audit event so reports survive the mailbox.
  """
  def report(domain, user_email, text) do
    text = String.slice(to_string(text || ""), 0, 2000)

    LS.Audit.record("feedback", %{
      email: user_email,
      metadata: %{domain: domain, text: text}
    })

    Task.start(fn ->
      email =
        new()
        |> to(@to)
        |> from({"ListSignal", "noreply@listsignal.com"})
        |> reply_to(user_email)
        |> subject("Feedback: #{domain} (from #{user_email})")
        |> text_body("""
        Domain:  #{domain}
        User:    #{user_email}

        #{if text == "", do: "(no text — user flagged the record without a message)", else: text}
        """)

      case LS.Mailer.deliver(email) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.warning("Feedback mail failed (audit row kept): #{inspect(reason)}")
      end
    end)

    :ok
  end
end
