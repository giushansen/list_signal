defmodule LSWeb.StoreControllerTest do
  use LSWeb.ConnCase, async: true

  describe "GET /store/:slug — country redirects" do
    test "redirects united-states to /top/shopify-stores-us", %{conn: conn} do
      conn = get(conn, "/store/united-states")
      assert redirected_to(conn, 301) == "/top/shopify-stores-us"
    end

    test "redirects united-kingdom to /top/shopify-stores-gb", %{conn: conn} do
      conn = get(conn, "/store/united-kingdom")
      assert redirected_to(conn, 301) == "/top/shopify-stores-gb"
    end

    test "redirects canada to /top/shopify-stores-ca", %{conn: conn} do
      conn = get(conn, "/store/canada")
      assert redirected_to(conn, 301) == "/top/shopify-stores-ca"
    end

    test "redirects france to /top/shopify-stores-fr", %{conn: conn} do
      conn = get(conn, "/store/france")
      assert redirected_to(conn, 301) == "/top/shopify-stores-fr"
    end

    test "redirects germany to /top/shopify-stores-de", %{conn: conn} do
      conn = get(conn, "/store/germany")
      assert redirected_to(conn, 301) == "/top/shopify-stores-de"
    end

    test "redirects australia to /top/shopify-stores-au", %{conn: conn} do
      conn = get(conn, "/store/australia")
      assert redirected_to(conn, 301) == "/top/shopify-stores-au"
    end

    test "non-country slug is treated as domain lookup", %{conn: conn} do
      conn = get(conn, "/store/example-com")
      # Should get 404 (domain doesn't exist) or 301 redirect — not a country redirect
      assert conn.status in [301, 404]
    end
  end
end
