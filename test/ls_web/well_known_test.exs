defmodule LSWeb.WellKnownTest do
  @moduledoc """
  The MCP registry fetches /.well-known/mcp-registry-auth and compares the
  signed record byte for byte before it will grant the `com.listsignal/*`
  namespace. A wrapped, reformatted or HTML-ified response fails the token
  exchange with a 401 and nobody finds out until a publish breaks, so the
  exact bytes and content type are pinned here.

  2026-10-04: added when the registry's DNS path was blocked (no Cloudflare
  credential) and HTTP domain proof became the way we claim the namespace.
  """
  use LSWeb.ConnCase, async: true

  test "the proof is served verbatim as text/plain, no wrapper, no trailing newline" do
    conn = get(build_conn(), "/.well-known/mcp-registry-auth")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> hd() =~ "text/plain"

    body = conn.resp_body
    assert body == LSWeb.WellKnownController.proof()
    refute String.ends_with?(body, "\n"), "a trailing newline fails the registry's byte comparison"
    refute body =~ "<", "an HTML wrapper fails the exchange"
  end

  test "the record carries the MCPv1 ed25519 public key the publisher signs with" do
    body = get(build_conn(), "/.well-known/mcp-registry-auth").resp_body

    assert body =~ ~r/^v=MCPv1; k=ed25519; p=[A-Za-z0-9+\/]{43}=$/,
           "expected 'v=MCPv1; k=ed25519; p=<base64 32-byte key>', got: #{inspect(body)}"
  end

  test "it is reachable without authentication, since the registry fetches it cold" do
    # No session, no API key, no redirect: the registry is an anonymous client.
    conn = get(build_conn(), "/.well-known/mcp-registry-auth")
    assert conn.status == 200
    refute conn.status in 300..399
  end
end
