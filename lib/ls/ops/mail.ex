defmodule LS.Ops.Mail do
  @moduledoc """
  The one place ops email (alerts + the weekly report) is sent from.

  Shares the configured `:mail_from` identity and `:alert_emails` recipients so
  a solo operator changes them in one env var, not in code. Delivery goes
  through `LS.Mailer` (Mailgun in prod); in dev/test the Local/Test adapter
  captures it, so calling this is always safe.
  """
  import Swoosh.Email
  require Logger

  @doc "Recipients of ops mail (from `LS_ALERT_EMAILS`)."
  def recipients, do: Application.get_env(:ls, :alert_emails, ["will@listsignal.com"])

  @doc "The shared From identity (from `MAIL_FROM`)."
  def from, do: Application.get_env(:ls, :mail_from, {"ListSignal", "team@listsignal.com"})

  @doc """
  Send an ops email. `body` is HTML; a plain-text fallback is derived from it.
  Returns `:ok` / `{:error, reason}` and never raises.
  """
  @spec send(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def send(subject, html, opts \\ []) when is_binary(subject) and is_binary(html) do
    case recipients() do
      [] ->
        Logger.warning("[OPS MAIL] no LS_ALERT_EMAILS configured, dropping #{inspect(subject)}")
        {:error, :no_recipients}

      to ->
        email =
          new()
          |> to(Enum.map(to, &{"", &1}))
          |> from(from())
          |> subject(subject)
          |> html_body(html)
          |> text_body(to_text(html))
          |> maybe_reply_to(opts[:reply_to])

        case LS.Mailer.deliver(email) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.error("[OPS MAIL] deliver failed: #{inspect(reason)}"); {:error, reason}
        end
    end
  rescue
    e -> Logger.error("[OPS MAIL] #{Exception.message(e)}"); {:error, Exception.message(e)}
  end

  # Let a flag/report email reply straight to the customer who sent it.
  defp maybe_reply_to(email, addr) when is_binary(addr) and addr != "", do: reply_to(email, addr)
  defp maybe_reply_to(email, _), do: email

  # Crude HTML→text so the multipart email always has a readable fallback.
  defp to_text(html) do
    html
    |> String.replace(~r/<\s*br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/(p|tr|h[1-6]|div|li)>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
