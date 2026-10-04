defmodule LSWeb.WellKnownController do
  @moduledoc """
  `/.well-known/*` endpoints that prove we control listsignal.com.

  Right now that is the MCP registry proof. The official registry
  (registry.modelcontextprotocol.io) grants the `com.listsignal/*`
  namespace to whoever can prove ownership of the domain, either with a
  DNS TXT record or by serving the same signed record over HTTPS here.
  Serving it from the app keeps the proof in version control and deploys
  with the code, instead of living only in a DNS panel nobody reads.

  The record is public by design: it carries the ed25519 PUBLIC key whose
  private half signs the publish request. The private key never leaves the
  operator's machine (`~/.config/listsignal/mcp-registry-ed25519.hex`); see
  `devops/listsignal/mcp-registry.md` for the rotation recipe.
  """
  use LSWeb, :controller

  @doc """
  The MCP registry ownership proof, as `text/plain`.

  Must be served verbatim: the registry fetches this URL and compares the
  key byte for byte, so a trailing newline or an HTML wrapper fails the
  exchange with a 401.
  """
  def mcp_registry_auth(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "public, max-age=300")
    |> send_resp(200, proof())
  end

  @doc "The configured proof record. Overridable so a key rotation needs no deploy."
  def proof, do: Application.get_env(:ls, :mcp_registry_proof, "")
end
