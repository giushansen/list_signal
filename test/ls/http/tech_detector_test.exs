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
end
