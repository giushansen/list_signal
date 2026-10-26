defmodule LSWeb.Plugs.HostGuard do
  @moduledoc """
  Answers only for the names this site is served under.

  Found 2026-10-26 in our own data: `ctf-nm.org`, proxied through
  Cloudflare, carried the ListSignal homepage as its title. Someone had
  pointed a name at our origin, and the origin served the site under any
  Host header, so our pages, and the mailbox address in the footer, were
  recorded as that business's. A request whose Host is not the configured
  site host, its `www.` form, or a local probe address gets 421 Misdirected
  Request and nothing else: no page, no cookie, no redirect.

  `LS_ALLOWED_HOSTS` (comma-separated) extends the list for a staging name.
  The watchdog probes `https://127.0.0.1:4000/pricing`, so loopback stays
  allowed; so does the master's mesh and public address for internal
  checks. The guard runs before the router and the parsers.
  """
  import Plug.Conn

  @local ~w(localhost 127.0.0.1 10.0.0.1 45.63.7.58)

  def init(opts), do: opts

  def call(conn, _opts) do
    if allowed?(conn.host, configured_host(), extra_hosts()),
      do: conn,
      else: conn |> put_resp_content_type("text/plain") |> send_resp(421, "Misdirected Request") |> halt()
  end

  @doc "Pure: is `host` one of ours? `site` is the configured host; `extra` the operator's list."
  @spec allowed?(term(), String.t() | nil, [String.t()]) :: boolean()
  def allowed?(host, site, extra \\ [])

  def allowed?(host, site, extra) when is_binary(host) do
    h = host |> String.downcase() |> String.trim_trailing(".")
    site = site && String.downcase(site)

    cond do
      h == "" -> false
      # An unconfigured site (dev, test) accepts everything, like before.
      is_nil(site) or site == "localhost" -> true
      h == site -> true
      h == "www." <> site -> true
      h in @local -> true
      h in Enum.map(extra, &String.downcase/1) -> true
      true -> false
    end
  end

  def allowed?(_, _, _), do: false

  defp configured_host do
    case LSWeb.Endpoint.config(:url) do
      url when is_list(url) -> Keyword.get(url, :host)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp extra_hosts do
    (System.get_env("LS_ALLOWED_HOSTS") || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end
end
