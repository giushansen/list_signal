defmodule LSWeb.McpKeyedUrlTest do
  @moduledoc """
  2026-10-18: claude.ai custom connectors take a URL and no header, so the
  key may ride in the path. Same ApiAuth behind it: a bad key is still 401,
  a header still wins, and the plain /mcp route is untouched.
  """
  use LSWeb.ConnCase, async: false

  setup do
    user = LS.AccountsFixtures.user_fixture()
    {:ok, plaintext, _key} = LS.ApiKeys.create_key(user)
    %{token: plaintext}
  end

  defp rpc(conn, path, method) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: %{}}))
  end

  test "the key in the path authenticates tools/list exactly like the header", %{conn: conn, token: token} do
    body = rpc(conn, "/mcp/k/#{token}", "tools/list") |> json_response(200)
    assert Enum.map(body["result"]["tools"], & &1["name"]) |> Enum.sort() |> Enum.member?("listsignal_changes")
  end

  test "a wrong key in the path is 401, and no key at /mcp is still 401", %{conn: conn} do
    assert rpc(conn, "/mcp/k/ls_not_a_key", "tools/list").status == 401
    assert rpc(conn, "/mcp", "tools/list").status == 401
  end

  test "a header, when present, is what counts even if the path has a key", %{conn: conn, token: token} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer ls_not_a_key")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp/k/#{token}", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "tools/list", params: %{}}))

    assert conn.status == 401
  end

  test "GET on the keyed route is refused the same way as on /mcp", %{conn: conn, token: token} do
    assert get(conn, "/mcp/k/#{token}").status == get(put_req_header(conn, "authorization", "Bearer #{token}"), "/mcp").status
  end
end
