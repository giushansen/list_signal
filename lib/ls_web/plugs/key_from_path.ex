defmodule LSWeb.Plugs.KeyFromPath do
  @moduledoc """
  Lets an MCP client that cannot send headers authenticate with the key in
  the URL: `https://listsignal.com/mcp/k/ls_YOUR_KEY`.

  Why (2026-10-18): claude.ai's custom connectors take a server URL and
  nothing else, no header field, and offer OAuth or no auth. Every other
  client (Claude Code, Claude Desktop, Cursor) sends `Authorization:
  Bearer`, which stays the documented way. This plug copies a `:key` path
  segment into that header when no header was sent, so `LSWeb.Plugs.ApiAuth`
  runs unchanged: same keys, same quota, same rate limit, same revocation.
  A key in a URL is a secret in a URL; the docs say to use a dedicated key
  that can be revoked on its own.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case {conn.path_params["key"], get_req_header(conn, "authorization"), get_req_header(conn, "x-api-key")} do
      {key, [], []} when is_binary(key) and key != "" -> put_req_header(conn, "authorization", "Bearer " <> key)
      _ -> conn
    end
  end
end
