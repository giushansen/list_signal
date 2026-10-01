defmodule LS.HTTP.PageBlocksTest do
  @moduledoc """
  The page-block extractor replaces the 500-character snippet that stored
  navigation menus (2026-10-01). These pin: document order, the three
  regions, hidden-node removal (the first sample row opened with "Your cart
  is empty" from a cart drawer), the caps, the footer scalars, JSON-LD, and
  the hostile-input rule: anything returns empty parts, nothing raises.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.PageBlocks

  @html """
  <!doctype html><html><head><title>Acme Tools</title>
  <script type="application/ld+json">{"@context":"https://schema.org","@type":"Organization","name":"Acme","telephone":"+44 20 7946 0958","address":{"streetAddress":"12 King Street","addressLocality":"London","postalCode":"EC2V 8EA","addressCountry":"GB"},"sameAs":["https://www.linkedin.com/company/acme-tools","https://twitter.com/acmetools"]}</script>
  <script src="https://cdn.example.com/app.js"></script><style>.x{}</style></head>
  <body>
  <header><nav><a href="/">Home</a><a href="/pricing">Pricing</a><a href="/careers">Careers</a></nav></header>
  <div class="cart-drawer" aria-hidden="true"><h2>Your cart is empty</h2><p>Have an account?</p></div>
  <main>
    <h1>Tools for growing teams</h1>
    <p>Acme makes the planning software 2,000 teams use every day.</p>
    <h2>Why Acme</h2>
    <ul><li>Fast</li><li>Fast</li><li>Fair pricing</li></ul>
    <p>   lots   of    whitespace &amp; entities   </p>
    <template><p>never shown</p></template>
  </main>
  <footer><p>Acme Ltd, 12 King Street, London EC2V 8EA</p><p>Company No. 09876543 &middot; VAT GB123456789</p>
  <a href="https://www.instagram.com/acmetools/">Instagram</a><a href="/privacy">Privacy policy</a><p>hello@acme.example</p></footer>
  </body></html>
  """

  test "body blocks keep document order and skip hidden drawers, scripts and templates" do
    parts = PageBlocks.extract(@html)

    assert parts.body == [
             {"h1", "Tools for growing teams"},
             {"p", "Acme makes the planning software 2,000 teams use every day."},
             {"h2", "Why Acme"},
             {"li", "Fast"},
             {"li", "Fair pricing"},
             {"p", "lots of whitespace & entities"}
           ]

    refute Enum.any?(parts.body, fn {_, t} -> t =~ "cart" end)
    refute Enum.any?(parts.body, fn {_, t} -> t =~ "never shown" end)
  end

  test "header gives the navigation link texts and footer keeps its own blocks" do
    parts = PageBlocks.extract(@html)
    assert parts.nav_links == ["Home", "Pricing", "Careers"]
    assert {"p", "Acme Ltd, 12 King Street, London EC2V 8EA"} in parts.footer
    assert Enum.any?(parts.footer, fn {_, t} -> t =~ "Company No" end)
  end

  test "footer and JSON-LD scalars: phone, address, company id, social links" do
    parts = PageBlocks.extract(@html)
    assert parts.phone == "+44 20 7946 0958"
    assert parts.address == "12 King Street, EC2V 8EA, London, GB"
    assert parts.company_id =~ "09876543"
    assert "https://www.linkedin.com/company/acme-tools" in parts.social_links
    assert "https://www.instagram.com/acmetools" in parts.social_links
    assert "https://twitter.com/acmetools" in parts.social_links
    assert parts.jsonld =~ ~s("@type":"Organization")
  end

  test "caps: at most 120 body blocks of 400 bytes, cut on a character boundary" do
    long = String.duplicate("é", 500)
    html = "<body>" <> Enum.map_join(1..200, "", fn i -> "<p>#{i} #{long}</p>" end) <> "</body>"
    parts = PageBlocks.extract(html)
    assert length(parts.body) == 120

    for {_, t} <- parts.body do
      assert byte_size(t) <= 400
      assert String.valid?(t)
    end
  end

  test "hostile input returns empty parts and never raises" do
    for input <- [nil, "", 42, <<0, 255, 254, 1>>, "<p", "<<<>>>", "</div></div><h1>", String.duplicate("<a>", 50_000)] do
      parts = PageBlocks.extract(input)
      assert is_list(parts.body)
      assert is_binary(parts.jsonld)
    end

    too_big = String.duplicate("x", 3_000_001)
    assert PageBlocks.extract(too_big).body == []
  end

  test "page_row/3 flattens the parts into the columns the inserter writes" do
    row = @html |> PageBlocks.extract() |> PageBlocks.page_row("home", "2026-10-01 00:00:00")
    assert row.page_kind == "home"
    assert row.http_fetched_at == "2026-10-01 00:00:00"
    assert length(row.http_body_tags) == length(row.http_body_texts)
    assert hd(row.http_body_tags) == "h1"
    assert row.http_jsonld =~ "Organization"
  end
end
