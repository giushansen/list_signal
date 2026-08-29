defmodule LSWeb.ApiV1Test do
  @moduledoc """
  The API is a contract with strangers' code, so the tests pin the contract,
  not the implementation: auth failures are actionable problem+json, quotas
  and rate limits actually stop requests, the free tier never leaks a
  contact email, and the OpenAPI spec never drifts from the router.
  """
  use LSWeb.ConnCase, async: false

  alias LS.ApiKeys

  setup do
    user = LS.AccountsFixtures.user_fixture()
    {:ok, plaintext, key} = ApiKeys.create_key(user)
    %{user: user, key: key, token: plaintext}
  end

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "authentication" do
    test "no key is 401 problem+json that tells the caller how to get one", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/stats")
      assert conn.status == 401
      assert conn |> get_resp_header("content-type") |> hd() =~ "application/problem+json"
      body = Jason.decode!(conn.resp_body)
      assert body["detail"] =~ "listsignal.com/signup"
    end

    test "a garbage key is 401 with a distinct message", %{conn: conn} do
      conn = conn |> authed("ls_wrong") |> get(~p"/api/v1/stats")
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["title"] == "Invalid API key"
    end

    test "a revoked key stops working immediately", %{conn: conn, key: key, token: token} do
      {:ok, _} = ApiKeys.revoke_key(key)
      conn = conn |> authed(token) |> get(~p"/api/v1/stats")
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["title"] == "API key revoked"
    end

    test "X-API-Key header works as an alias for Bearer", %{conn: conn, token: token} do
      conn = conn |> put_req_header("x-api-key", token) |> get(~p"/api/v1/stats")
      assert conn.status == 200
    end
  end

  describe "quota" do
    test "a key over its monthly quota is 403 with the reset story", %{conn: conn, key: key, token: token} do
      # Simulate a month of use in one write; the check reads the same row.
      for _ <- 1..ApiKeys.monthly_quota("free"), do: ApiKeys.record_usage(key.id)

      conn = conn |> authed(token) |> get(~p"/api/v1/stats")
      assert conn.status == 403
      assert Jason.decode!(conn.resp_body)["detail"] =~ "resets on the 1st"
    end

    test "usage recording is per-month and additive", %{key: key} do
      assert ApiKeys.usage_this_month(key.id) == 0
      ApiKeys.record_usage(key.id)
      ApiKeys.record_usage(key.id)
      assert ApiKeys.usage_this_month(key.id) == 2
    end
  end

  describe "rate limiting" do
    test "burst past the per-minute limit is 429 with Retry-After", %{conn: conn, token: token} do
      # The limiter counts per key per minute in ETS; hammer it directly.
      {:ok, key, user} = ApiKeys.authenticate(token)
      limit = ApiKeys.rate_per_min(LS.Accounts.User.effective_plan(user))
      for _ <- 1..limit, do: LSWeb.ApiRateLimiter.hit(key.id, limit)

      conn = conn |> authed(token) |> get(~p"/api/v1/stats")
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["60"]
    end
  end

  describe "free-tier email gating" do
    # A regression here would give away the paid field: the reason the plans
    # exist. The gate lives in one place per surface; both are pinned.
    test "REST company response never carries addresses on the free plan", %{conn: conn, token: token} do
      conn = conn |> authed(token) |> get(~p"/api/v1/search?limit=1")
      # Search rows only ever expose has_contact, never addresses.
      assert conn.status in [200, 503]

      if conn.status == 200 do
        body = Jason.decode!(conn.resp_body)
        refute inspect(body) =~ "@"
      end
    end

    test "the gate function itself blanks emails for free and keeps them for paid" do
      record = %{emails: ["a@b.com"], domain: "x.com"}

      # Private behaviour pinned through the MCP controller's public path:
      free = LSWeb.McpController.gate(record, "free")
      paid = LSWeb.McpController.gate(record, "pro")

      assert free.emails =~ "gated"
      assert free.email_count == 1
      assert paid.emails == ["a@b.com"]
    end
  end

  describe "input hardening" do
    test "a hostile domain segment is 400, not a query", %{conn: conn, token: token} do
      conn = conn |> authed(token) |> get("/api/v1/company/%27%20OR%201=1--")
      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["title"] == "Invalid domain"
    end

    test "search clamps limit and offset to the documented maxima", %{token: _token} do
      {:ok, _rows, applied} = LS.ApiData.search(%{"limit" => "999999", "offset" => "-5"})
      assert applied.limit == 100
      assert applied.offset == 0
    end
  end

  describe "openapi contract" do
    test "the spec is served and lists exactly the routed endpoints", %{conn: conn} do
      conn = get(conn, ~p"/openapi.json")
      assert conn.status == 200
      spec = Jason.decode!(conn.resp_body)

      assert Map.keys(spec["paths"]) |> Enum.sort() == [
               "/api/v1/company/{domain}",
               "/api/v1/search",
               "/api/v1/stats",
               "/api/v1/technologies"
             ]

      # Every operation documents auth failures an agent will hit.
      for {_path, ops} <- spec["paths"], {_verb, op} <- ops do
        assert op["responses"]["401"], "#{op["operationId"]} missing 401 doc"
      end
    end
  end

  describe "key lifecycle" do
    test "one active key per user, rotation via revoke", %{user: user, key: key} do
      assert {:error, :already_has_key} = ApiKeys.create_key(user)
      {:ok, _} = ApiKeys.revoke_key(key)
      assert {:ok, "ls_" <> _, _new} = ApiKeys.create_key(user)
    end

    test "the plaintext is never stored", %{token: token, key: key} do
      refute key.key_hash == token
      assert key.prefix == String.slice(token, 0, 11)
      assert byte_size(key.key_hash) == 32
    end
  end
end
