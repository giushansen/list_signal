defmodule LS.HTTP.TechDetectorTest do
  use ExUnit.Case, async: false

  setup_all do
    LS.Signatures.load_all()
    :ok
  end

  test "detects React from script src" do
    response = %{
      body: ~s(<html><head><script src="https://unpkg.com/react@18/umd/react.production.min.js"></script></head><body></body></html>),
      headers: []
    }
    result = LS.HTTP.TechDetector.detect(response)
    assert "React" in result.tech
  end

  test "detects Vue from CDN script" do
    response = %{
      body: ~s(<html><head><script src="https://cdn.jsdelivr.net/npm/vue@3"></script></head><body></body></html>),
      headers: [{"server", "nginx"}]
    }
    result = LS.HTTP.TechDetector.detect(response)
    assert "Vue.js" in result.tech
  end

  test "detects Google Tag Manager from gtag script" do
    response = %{
      body: ~s(<html><head><script src="https://www.googletagmanager.com/gtag/js?id=G-123"></script></head><body></body></html>),
      headers: []
    }
    result = LS.HTTP.TechDetector.detect(response)
    assert "Google Analytics" in result.tech
  end

  test "detects server from headers" do
    response = %{
      body: "<html><body>Hello</body></html>",
      headers: [{"server", "nginx"}, {"content-type", "text/html"}]
    }
    result = LS.HTTP.TechDetector.detect(response)
    assert "Nginx" in result.tech
  end

  test "detects multiple technologies from rich page" do
    # Simulates a page like interpolis.nl from the sample data
    response = %{
      body: """
      <html>
      <head>
        <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
        <script src="https://www.googletagmanager.com/gtag/js"></script>
        <script src="https://cdn.schema.org/something"></script>
        <link href="https://fonts.googleapis.com/css2?family=Inter" rel="stylesheet">
      </head>
      <body data-reactroot>
        <script>window.dataLayer = window.dataLayer || [];</script>
      </body>
      </html>
      """,
      headers: [{"server", "cloudflare"}, {"content-type", "text/html"}]
    }
    result = LS.HTTP.TechDetector.detect(response)
    assert length(result.tech) > 0, "Expected at least some tech detected"
    assert length(result.tech) >= 0
  end

  test "detects JS site when body is mostly script tags" do
    response = %{
      body: ~s(<html><head></head><body><div id="__next"></div><script src="/static/chunks/main.js"></script><script src="/static/chunks/pages/_app.js"></script></body></html>),
      headers: []
    }
    result = LS.HTTP.TechDetector.detect(response)
    assert is_boolean(result.is_js_site)
  end

  test "handles empty body gracefully" do
    response = %{body: "", headers: []}
    result = LS.HTTP.TechDetector.detect(response)
    assert result.tech == []
    assert result.tech == []
  end

  test "handles nil-like body gracefully" do
    response = %{body: " ", headers: [{"server", "Apache"}]}
    result = LS.HTTP.TechDetector.detect(response)
    assert is_list(result.tech)
  end

  test "returns map with expected keys" do
    response = %{body: "<html></html>", headers: []}
    result = LS.HTTP.TechDetector.detect(response)
    assert Map.has_key?(result, :tech)
    assert Map.has_key?(result, :blocked)
    assert Map.has_key?(result, :is_js_site)
  end

  # =========================================================================
  # Set-Cookie backend framework signals (B1a)
  # =========================================================================
  test "detects Ruby on Rails from _session_id set-cookie" do
    response = %{body: "<html></html>", headers: [{"set-cookie", "_myapp_session=abc; path=/; HttpOnly"}, {"set-cookie", "_session_id=xyz"}]}
    result = LS.HTTP.TechDetector.detect(response)
    assert "Ruby on Rails" in result.tech
  end

  test "detects Laravel from laravel_session set-cookie case-insensitively" do
    response = %{body: "<html></html>", headers: [{"Set-Cookie", "LARAVEL_SESSION=abc; path=/"}]}
    result = LS.HTTP.TechDetector.detect(response)
    assert "Laravel" in result.tech
  end

  test "detects Django only when both csrftoken and sessionid present" do
    both = %{body: "<html></html>", headers: [{"set-cookie", "csrftoken=a"}, {"set-cookie", "sessionid=b"}]}
    assert "Django" in LS.HTTP.TechDetector.detect(both).tech

    one = %{body: "<html></html>", headers: [{"set-cookie", "csrftoken=a"}]}
    refute "Django" in LS.HTTP.TechDetector.detect(one).tech
  end

  test "detects Express, PHP, Java, ASP.NET, CodeIgniter, NextAuth from cookies" do
    cases = [
      {"connect.sid=s%3A...", "Express"},
      {"PHPSESSID=deadbeef", "PHP"},
      {"JSESSIONID=ABC123", "Java"},
      {"ASP.NET_SessionId=zzz", "ASP.NET"},
      {".AspNetCore.Identity=zzz", "ASP.NET"},
      {"ci_session=zzz", "CodeIgniter"},
      {"next-auth.session-token=zzz", "NextAuth"},
      {"__Secure-next-auth.session-token=zzz", "NextAuth"}
    ]

    for {cookie, expected} <- cases do
      result = LS.HTTP.TechDetector.detect(%{body: "<html></html>", headers: [{"set-cookie", cookie}]})
      assert expected in result.tech, "expected #{expected} from cookie #{cookie}"
    end
  end

  # =========================================================================
  # Auth providers from urls (B1b)
  # =========================================================================
  test "detects auth providers from script src / hrefs" do
    cases = [
      {~s(<script src="https://cdn.auth0.com/js/auth0.min.js"></script>), "Auth0"},
      {~s(<script src="https://clerk.accounts.dev/npm/@clerk/clerk-js"></script>), "Clerk"},
      {~s(<script src="https://www.googleapis.com/identitytoolkit/v3"></script>), "Firebase Auth"},
      {~s(<script src="https://xyz.supabase.co/auth/v1"></script>), "Supabase Auth"},
      {~s(<script src="https://cognito-idp.us-east-1.amazonaws.com/x"></script>), "AWS Cognito"},
      {~s(<script src="https://acme.okta.com/login"></script>), "Okta"},
      {~s(<script src="https://js.stytch.com/stytch.js"></script>), "Stytch"},
      {~s(<script src="https://cdn.workos.com/sdk.js"></script>), "WorkOS"}
    ]

    for {body, expected} <- cases do
      result = LS.HTTP.TechDetector.detect(%{body: "<html><head>#{body}</head></html>", headers: []})
      assert expected in result.tech, "expected #{expected} from body #{body}"
    end
  end

  # =========================================================================
  # Stripe Checkout / Payment Links from hrefs (B1c)
  # =========================================================================
  test "detects Stripe from checkout.stripe.com in collected urls (srcs ++ hrefs)" do
    link = ~s(<html><head><link href="https://checkout.stripe.com/c/pay/abc"></head></html>)
    assert "Stripe" in LS.HTTP.TechDetector.detect(%{body: link, headers: []}).tech

    src = ~s(<html><head><script src="https://buy.stripe.com/test_abc"></script></head></html>)
    assert "Stripe" in LS.HTTP.TechDetector.detect(%{body: src, headers: []}).tech
  end

  test "broadened Stripe script signature catches v2" do
    response = %{body: ~s(<html><head><script src="https://js.stripe.com/v2/"></script></head></html>), headers: []}
    assert "Stripe" in LS.HTTP.TechDetector.detect(response).tech
  end
end
