defmodule LSWeb.CSPTest do
  use LSWeb.ConnCase, async: true

  @moduledoc """
  Content-Security-Policy (security audit 2026-09-09). The pages render text
  scraped from hostile websites; the policy is what keeps an escaped-by-
  mistake `<script>` from running. It only works if every script we ship
  carries the nonce and no template uses an inline event handler, which is
  what these tests pin.
  """

  @web_files Path.wildcard("lib/ls_web/**/*.{ex,heex}")

  test "public pages carry the policy with a fresh nonce" do
    conn = get(build_conn(), "/")
    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ ~r/script-src 'self' 'nonce-[A-Za-z0-9_-]{20,}'/
    assert csp =~ "object-src 'none'"
    assert csp =~ "form-action 'self' https://checkout.stripe.com"

    [csp2] = build_conn() |> get("/") |> get_resp_header("content-security-policy")
    refute csp == csp2, "the nonce must differ per request or it is not a nonce"
  end

  test "the pricing page's own script carries the request nonce and uses no inline handler" do
    conn = get(build_conn(), "/pricing")
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
    body = html_response(conn, 200)
    assert body =~ ~s(<script nonce="#{nonce}">)
    refute body =~ ~r/\son[a-z]+="/, "inline event handlers are blocked by the policy"
  end

  test "the dashboard root loads app.js with the request nonce" do
    %{conn: conn} = register_and_log_in_user(%{conn: build_conn()})
    conn = get(conn, "/dashboard")
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
    assert html_response(conn, 200) =~ ~s(src="/assets/app.js" nonce="#{nonce}")
  end

  test "no template uses an inline event handler or a nonce-less inline script" do
    offenders =
      for f <- @web_files,
          body = File.read!(f),
          line <- String.split(body, "\n"),
          (line =~ ~r/\son[a-z]+=["']/ and not (line =~ ~r/^\s*(#|<%!--)/)) or
            line =~ ~r/^\s*<script(?![^>]*(nonce=|src=|type="application\/ld\+json"))[^>]*>/,
          do: "#{f}: #{String.trim(line)}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  test "JSON-LD cannot close its own script block" do
    json = Jason.encode!(%{"name" => "Evil </script><script>alert(1)</script>"})
    safe = LSWeb.JsonLD.safe(json)
    refute safe =~ "</script>"
    refute safe =~ "<script"
    assert Jason.decode!(safe) == Jason.decode!(json), "escaping must not change the document"
    assert LSWeb.JsonLD.safe(nil) == ""
  end
end
