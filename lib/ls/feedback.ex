defmodule LS.Feedback do
  @moduledoc """
  A customer flagging a domain on the dashboard → an immediate email to the
  operator, plus an audit row so the report survives the mailbox.

  Sent even when the reason is empty: the datetime, the reporter's address and
  the domain are already actionable — the owner can open the record and reply
  straight to the customer (the email's Reply-To is the reporter) — and
  demanding prose loses exactly the users who would click once and move on.

  Routes through `LS.Ops.Mail`, so flag emails share the same recipients
  (`LS_ALERT_EMAILS`) and From identity (`MAIL_FROM`) as every other operator
  email. The build/send runs off-process so a mail hiccup can neither crash the
  LiveView nor add latency to the button click.
  """

  require Logger

  @doc """
  Report a customer flag on `domain` from `user_email`, optional `text` reason.
  Immediate, never raises. Returns `:ok`.
  """
  def report(domain, user_email, text) do
    at = DateTime.utc_now() |> DateTime.truncate(:second)
    reason = String.slice(to_string(text || ""), 0, 2000)

    LS.Audit.record("feedback", %{
      email: user_email,
      metadata: %{domain: domain, text: reason, flagged_at: DateTime.to_iso8601(at)}
    })

    Task.start(fn ->
      subject = "🚩 Domain flagged: #{domain} (from #{user_email})"

      case LS.Ops.Mail.send(subject, flag_html(domain, user_email, reason, at), reply_to: user_email) do
        :ok -> :ok
        other -> Logger.warning("[FEEDBACK] flag mail failed (audit row kept): #{inspect(other)}")
      end
    end)

    :ok
  end

  @doc "The flag email body (pure): the four fields the owner asked for, reason optional."
  def flag_html(domain, user_email, reason, %DateTime{} = at) do
    reason_row =
      if reason == "" do
        "<tr><td style=\"padding:6px 12px;color:#667085\">Reason</td><td style=\"padding:6px 12px;color:#999\"><i>none given, flagged without a message</i></td></tr>"
      else
        "<tr><td style=\"padding:6px 12px;color:#667085;vertical-align:top\">Reason</td><td style=\"padding:6px 12px;white-space:pre-wrap\">#{esc(reason)}</td></tr>"
      end

    """
    <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;max-width:600px">
      <h2 style="margin:0 0 4px">🚩 A customer flagged a domain</h2>
      <p style="color:#667085;margin:0 0 16px;font-size:13px">Reply to this email to answer the customer directly.</p>
      <table style="border-collapse:collapse;width:100%;border:1px solid #eef0f4;border-radius:8px">
        <tr><td style="padding:6px 12px;color:#667085;width:110px">When</td><td style="padding:6px 12px">#{at |> DateTime.to_naive() |> NaiveDateTime.to_string()} UTC</td></tr>
        <tr><td style="padding:6px 12px;color:#667085">Customer</td><td style="padding:6px 12px"><a href="mailto:#{esc(user_email)}">#{esc(user_email)}</a></td></tr>
        <tr><td style="padding:6px 12px;color:#667085">Domain</td><td style="padding:6px 12px"><b>#{esc(domain)}</b> · <a href="https://#{esc(domain)}">visit</a></td></tr>
        #{reason_row}
      </table>
    </div>
    """
  end

  defp esc(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
end
