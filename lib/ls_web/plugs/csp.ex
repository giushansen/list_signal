defmodule LSWeb.Plugs.CSP do
  @moduledoc """
  Content-Security-Policy with a per-request script nonce.

  Security audit 2026-09-09: the pages render third-party text scraped from
  hostile sites (titles, descriptions, app names). HEEx escapes it, and the
  audit found no injection, but a policy is the guard for the one nobody has
  found yet: with it, an injected `<script>` does not run and an injected
  form cannot post the session elsewhere.

  What the policy allows is exactly what the pages use: our own assets,
  the Umami tracker host, Google Fonts, inline styles (Tailwind utilities
  and a few `style=` attributes), images from anywhere over https (store
  favicons), LiveView's websocket, and form posts to Stripe's hosted
  checkout, which the billing controller reaches by redirect after a form
  submit (Chrome applies `form-action` to that redirect).

  The nonce is assigned as `:csp_nonce`; the root layouts put it on the
  app.js tag. Inline event handlers (`onclick=`) are not allowed by design,
  which `LSWeb.CSPTest` enforces on the templates.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  @doc "The policy string for one request's nonce. Public so tests can pin it."
  @spec policy(String.t()) :: String.t()
  def policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}' #{umami_origin()}",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src 'self' data: https://fonts.gstatic.com",
        "img-src 'self' data: https:",
        "connect-src 'self' wss: #{umami_origin()}",
        "form-action 'self' https://checkout.stripe.com https://billing.stripe.com",
        "frame-ancestors 'self'",
        "object-src 'none'",
        "base-uri 'self'"
      ],
      "; "
    )
  end

  defp umami_origin do
    src = Application.get_env(:ls, :umami, [])[:src] || "https://stats.listsignal.com/script.js"
    %URI{scheme: scheme, host: host} = URI.parse(src)
    "#{scheme}://#{host}"
  end
end
