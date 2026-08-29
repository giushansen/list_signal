defmodule LSWeb.McpTest do
  @moduledoc """
  The MCP endpoint is what Claude/Cursor actually speak; these tests walk
  the same JSON-RPC sequence a real client sends (initialize → tools/list →
  tools/call) and pin the shapes those clients depend on.
  """
  use LSWeb.ConnCase, async: false

  setup do
    user = LS.AccountsFixtures.user_fixture()
    {:ok, plaintext, _key} = LS.ApiKeys.create_key(user)
    %{token: plaintext}
  end

  defp rpc(conn, token, method, params \\ %{}, id \\ 1) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}))
  end

  test "initialize returns protocol version, server info and instructions", %{conn: conn, token: token} do
    body = rpc(conn, token, "initialize") |> json_response(200)

    assert body["jsonrpc"] == "2.0"
    assert body["result"]["protocolVersion"] == "2025-06-18"
    assert body["result"]["serverInfo"]["name"] == "listsignal"
    assert body["result"]["instructions"] =~ "listsignal_search_companies"
  end

  test "tools/list exposes exactly the three namespaced tools with schemas", %{conn: conn, token: token} do
    body = rpc(conn, token, "tools/list") |> json_response(200)
    tools = body["result"]["tools"]

    assert Enum.map(tools, & &1["name"]) |> Enum.sort() == [
             "listsignal_dataset_stats",
             "listsignal_get_company",
             "listsignal_search_companies"
           ]

    # Descriptions are the agent-facing UI; an empty one is a broken tool.
    for t <- tools do
      assert String.length(t["description"]) > 60
      assert t["inputSchema"]["type"] == "object"
    end
  end

  test "tools/call dataset_stats returns JSON text content", %{conn: conn, token: token} do
    body = rpc(conn, token, "tools/call", %{name: "listsignal_dataset_stats", arguments: %{}}) |> json_response(200)

    assert body["result"]["isError"] == false
    assert [%{"type" => "text", "text" => text}] = body["result"]["content"]
    assert {:ok, stats} = Jason.decode(text)
    assert Map.has_key?(stats, "businesses_tracked")
  end

  test "a bad tool argument is an in-band tool error the model can read, not a protocol error", %{conn: conn, token: token} do
    body = rpc(conn, token, "tools/call", %{name: "listsignal_get_company", arguments: %{}}) |> json_response(200)

    assert body["result"]["isError"] == true
    assert [%{"text" => msg}] = body["result"]["content"]
    assert msg =~ "domain"
    refute Map.has_key?(body, "error")
  end

  test "an unknown method is JSON-RPC -32601 naming what IS implemented", %{conn: conn, token: token} do
    body = rpc(conn, token, "resources/list") |> json_response(200)
    assert body["error"]["code"] == -32601
    assert body["error"]["message"] =~ "tools/call"
  end

  test "unauthenticated MCP requests get the same problem+json as the REST API", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "initialize"}))

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["detail"] =~ "signup"
  end

  test "GET declines the SSE stream politely", %{conn: conn, token: token} do
    conn = conn |> put_req_header("authorization", "Bearer #{token}") |> get("/mcp")
    assert conn.status == 405
  end
end
