defmodule LS.EmailLayout do
  @moduledoc """
  The shared look for every customer email.

  Deliberately minimal: these are a founder's notes, not branded campaigns, so
  the HTML is paragraphs and one accent colour. Its real job is hiding URLs
  behind words. A raw `?ref=email-unlock-export` in the body reads like
  tracking, which is exactly what it is, and customers should not have to look
  at our attribution plumbing.

  Every email is sent multipart: HTML for the ~99% of clients that render it,
  and a text fallback that keeps the raw URLs so a plain-text reader can still
  click through. That fallback is the reason the text bodies still show full
  links, and why they must keep doing so.
  """

  @accent "#10b981"
  @shell "font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;" <>
           "font-size:15px;line-height:1.6;color:#1a1a1a;max-width:560px"

  @doc "Wrap paragraphs in the standard shell."
  def shell(inner), do: ~s(<div style="#{@shell}">#{inner}</div>)

  @doc "A normal paragraph."
  def p(html), do: ~s(<p style="margin:0 0 16px">#{html}</p>)

  @doc "The one thing we want clicked, as words rather than a URL."
  def cta(url, label) do
    ~s(<p style="margin:0 0 16px"><a href="#{url}" style="color:#{@accent};font-weight:600;text-decoration:none">#{label}</a></p>)
  end

  @doc "An inline link inside running text."
  def link(url, label), do: ~s(<a href="#{url}" style="color:#{@accent};text-decoration:none">#{label}</a>)

  @doc "A short list, styled tight so it reads as part of the note."
  def bullets(items) do
    lis = Enum.map_join(items, "", &~s(<li style="margin:0 0 4px">#{&1}</li>))
    ~s(<ul style="margin:0 0 16px;padding-left:20px">#{lis}</ul>)
  end

  @doc "Small print (unsubscribe, disclaimers)."
  def fine(html), do: ~s(<p style="margin:24px 0 0;font-size:12px;color:#999">#{html}</p>)

  @doc "Escape untrusted text before it reaches an email body."
  def esc(s), do: s |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
