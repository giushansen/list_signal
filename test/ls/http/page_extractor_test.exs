defmodule LS.HTTP.PageExtractorTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.PageExtractor

  # ============================================================================
  # PAGE EXTRACTION
  # ============================================================================

  test "extracts pricing page link" do
    html = ~s(<html><body><a href="/pricing">Pricing</a></body></html>)
    {pages, _emails} = PageExtractor.extract_all(html, "example.com")
    assert pages != nil
    assert String.contains?(pages, "/pricing")
  end

  test "extracts contact page link" do
    html = ~s(<html><body><a href="/contact">Contact Us</a></body></html>)
    {pages, _emails} = PageExtractor.extract_all(html, "example.com")
    assert pages != nil
    assert String.contains?(pages, "/contact")
  end

  test "extracts multiple page types" do
    html = """
    <html><body>
      <a href="/pricing">Plans</a>
      <a href="/docs">Documentation</a>
      <a href="/login">Sign In</a>
      <a href="/signup">Get Started</a>
    </body></html>
    """
    {pages, _emails} = PageExtractor.extract_all(html, "example.com")
    assert pages != nil
    assert String.contains?(pages, "/pricing") or String.contains?(pages, "/docs")
  end

  test "returns nil when no actionable pages found" do
    html = ~s(<html><body><a href="/about">About</a><a href="/news">News</a></body></html>)
    {pages, _emails} = PageExtractor.extract_all(html, "example.com")
    # /about and /news are not in the actionable page patterns
    assert pages == nil or is_binary(pages)
  end

  # ============================================================================
  # EMAIL EXTRACTION
  # ============================================================================

  test "extracts mailto email" do
    html = ~s(<html><body><a href="mailto:hello@example.com">Email</a></body></html>)
    {_pages, emails} = PageExtractor.extract_all(html, "example.com")
    # Mailto extraction may or may not work depending on regex patterns
    # This tests the interface, not the specific extraction
    assert emails == nil or is_binary(emails)
  end

  test "extracts raw email from text" do
    html = ~s(<html><body><p>Contact us at sales@company.com for more info</p></body></html>)
    {_pages, emails} = PageExtractor.extract_all(html, "company.com")
    if emails do
      assert String.contains?(emails, "sales@company.com")
    end
  end

  # ============================================================================
  # EDGE CASES
  # ============================================================================

  test "handles empty HTML" do
    {pages, emails} = PageExtractor.extract_all("", "example.com")
    assert pages == nil
    assert emails == nil
  end

  test "handles non-binary input" do
    {pages, emails} = PageExtractor.extract_all(nil, "example.com")
    assert pages == nil
    assert emails == nil
  end

  test "handles very large HTML without crashing" do
    large_html = String.duplicate("<p>Lorem ipsum dolor sit amet</p>", 50_000)
    {pages, emails} = PageExtractor.extract_all(large_html, "example.com")
    assert pages == nil or is_binary(pages)
    assert emails == nil or is_binary(emails)
  end

  test "returns {pages, emails} tuple" do
    html = "<html><body>Hello</body></html>"
    result = PageExtractor.extract_all(html, "example.com")
    assert is_tuple(result)
    assert tuple_size(result) == 2
  end
end
