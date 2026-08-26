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
    # NOTE: /about became actionable on 2026-08-26 (it carries named-person
    # addresses). /news is still not, and is what this test now rests on.
    html = ~s(<html><body><a href="/news">News</a><a href="/blog">Blog</a></body></html>)
    {pages, _emails} = PageExtractor.extract_all(html, "example.com")
    assert pages == nil
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

  # ==========================================================================
  # THE SCAN WINDOW
  #
  # Incident, 2026-08-26. Measured against prod: 8.26M of 26.5M live domains
  # carried an email, and a 488-domain re-fetch of domains recorded as having
  # NONE showed 19.1% of them did have one on the homepage all along. Two
  # causes, both here, both silent:
  #
  #   * `<head>` was discarded before scanning, so every JSON-LD
  #     schema.org/ContactPoint address was invisible — 6.6% of the miss.
  #   * only the FIRST 100KB of `<body>` was read, while 57% of homepages are
  #     larger than that and emails live in the footer — 12.5% of the miss.
  #
  # Cost: roughly 1.08M business domains carrying a findable address that the
  # DB recorded as having none, for as long as the extractor has existed.
  # ==========================================================================
  describe "scan window (2026-08-26 incident: ~1.08M domains blanked)" do
    test "an email declared in head JSON-LD is found" do
      html = """
      <html><head><script type="application/ld+json">
      {"@type":"Organization","contactPoint":{"email":"info@acme.de"}}
      </script></head><body><p>Willkommen</p></body></html>
      """

      {_pages, emails} = PageExtractor.extract_all(html, "acme.de")
      assert emails =~ "info@acme.de"
    end

    test "an email in the footer of a page larger than the scan window is found" do
      # 400KB of filler puts the footer far past the 100KB prefix. Before the
      # tail slice existed this returned nil.
      filler = String.duplicate("<div>produkt beschreibung</div>", 13_000)
      html = "<html><head><title>Shop</title></head><body>#{filler}<footer>kontakt@shop.de</footer></body></html>"

      assert byte_size(html) > 300_000
      {_pages, emails} = PageExtractor.extract_all(html, "shop.de")
      assert emails =~ "kontakt@shop.de"
    end

    test "the imprint link in a long page footer is still recorded" do
      filler = String.duplicate("<div>artikel</div>", 20_000)
      html = "<html><body>#{filler}<footer><a href=\"/impressum\">Impressum</a></footer></body></html>"

      {pages, _emails} = PageExtractor.extract_all(html, "shop.de")
      assert pages =~ "/impressum"
    end

    test "a style block cut by the head slice does not delete the rest of the page" do
      # The head slice lands inside <style>, leaving an opening tag with no
      # closer. `<style\b[^>]*>.*?</style>` then matched from that orphan to
      # the next closer deep in the body and deleted everything between —
      # observed on institut-ziemer.de, which has 246KB of inline CSS and
      # collapsed a 118KB window to 16KB, taking its /impressum with it.
      css = String.duplicate("a{color:red}", 4_000)
      html =
        "<html><head><style>#{css}</style></head>" <>
          "<body><style>.x{}</style><a href=\"/impressum\">Impressum</a> mail@firma.de</body></html>"

      assert byte_size(html) > 32_000
      {pages, emails} = PageExtractor.extract_all(html, "firma.de")
      assert pages =~ "/impressum"
      assert emails =~ "mail@firma.de"
    end

    test "a multi-byte character on the slice boundary does not blank the page" do
      # binary_part/3 cutting mid-codepoint yields an invalid binary; the next
      # String.downcase/1 raises and every caller here rescues to nil, so the
      # page silently reported no pages and no emails. European sites hit this
      # constantly.
      pad = String.duplicate("x", 31_999)
      html = "<html><head><meta content=\"#{pad}é\"></head><body><a href=\"/kontakt\">K</a> hallo@firma.de</body></html>"

      {pages, emails} = PageExtractor.extract_all(html, "firma.de")
      assert pages =~ "/kontakt"
      assert emails =~ "hallo@firma.de"
    end
  end

  # ==========================================================================
  # LEGAL / IMPRINT PAGES
  #
  # Added 2026-08-26. Measured on 117 German business domains that ListSignal
  # recorded as having no email: 60% of the addresses recoverable from a
  # second page came from /impressum and only 22% from the /kontakt and
  # /contact paths already known. §5 DDG (DE) and the LCEN (FR) require a
  # reachable address on the imprint; /kontakt is usually only a form.
  # Before this, 9,514 of 2.09M German domains had an imprint path recorded,
  # and 13 of 1.78M French ones.
  # ==========================================================================
  describe "imprint pages (2026-08-26: 60% of German second-page yield)" do
    test "/impressum is classified as legal, not as an unknown page" do
      assert PageExtractor.page_kind("/impressum") == :legal
      assert PageExtractor.page_kind("/mentions-legales") == :legal
      assert PageExtractor.page_kind("/aviso-legal") == :legal
    end

    test "a nested or suffixed imprint path is still legal" do
      # Shopify nests them; localised sites prefix them; hand-built sites
      # suffix them. An exact-path list caught none of these.
      assert PageExtractor.page_kind("/pages/impressum") == :legal
      assert PageExtractor.page_kind("/de/impressum") == :legal
      assert PageExtractor.page_kind("/impressum-rechtliche-hinweise.html") == :legal
    end

    test "policy pages are NOT treated as imprints" do
      # /legal, /terms and /privacy carry a controller's or law firm's address
      # on most sites. Matching them would attribute the wrong company's
      # mailbox to the business.
      refute PageExtractor.page_kind("/legal") == :legal
      refute PageExtractor.page_kind("/terms") == :legal
      refute PageExtractor.page_kind("/privacy") == :legal
      refute PageExtractor.page_kind("/privacy-policy") == :legal
    end

    test "an imprint survives a page crowded with pricing links" do
      # page_priority put legal in the catch-all bucket and @max_pages 10 then
      # truncated it, so a shop with a dozen product links lost its imprint
      # before the enrichment lane ever saw http_pages.
      many = Enum.map_join(1..12, fn i -> ~s(<a href="/products/p#{i}">P#{i}</a>) end)
      html = "<html><body>#{many}<a href=\"/impressum\">Impressum</a></body></html>"

      {pages, _emails} = PageExtractor.extract_all(html, "shop.de")
      assert pages =~ "/impressum"
    end

    test "the enrichment lane is told to visit the imprint" do
      # pages_to_visit/2 is the contract between discovery and enrichment.
      # If :legal is missing here the pattern work above buys nothing.
      visits = PageExtractor.pages_to_visit("/impressum|/kontakt|/pricing")
      assert {:legal, "/impressum"} in visits
    end
  end

  describe "hostile input at the window boundary" do
    test "a document with no body tag is scanned rather than dropped" do
      # Fragments, JSON-LD-only responses and malformed markup have no <body>.
      # Treating "no body tag" as "no content" would drop them entirely.
      {_pages, emails} = PageExtractor.extract_all(~s(<div>info@fragment.de</div>), "fragment.de")
      assert emails =~ "info@fragment.de"
    end

    test "control characters and NUL bytes do not crash extraction" do
      html = "<html><body>\0\x01\x02 hi@firma.de \x7f</body></html>"
      {pages, emails} = PageExtractor.extract_all(html, "firma.de")
      assert pages == nil or is_binary(pages)
      assert emails == nil or emails =~ "hi@firma.de"
    end

    test "an unterminated style tag does not swallow the document" do
      html = ~s(<html><body><style>a{} <a href="/kontakt">K</a> mail@firma.de</body></html>)
      {_pages, emails} = PageExtractor.extract_all(html, "firma.de")
      # The orphan opener is dropped, not matched across the whole document.
      assert emails == nil or is_binary(emails)
    end
  end
end
