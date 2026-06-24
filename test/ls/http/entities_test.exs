defmodule LS.HTTP.EntitiesTest do
  use ExUnit.Case, async: true
  alias LS.HTTP.Entities

  test "decodes the reported Linktree description to readable text" do
    raw =
      "Join 70M+ creators and sell, share &amp; curate everything you do online. " <>
        "One bio link—your Linktree—brings it all together for your audience."

    assert Entities.decode(raw) ==
             "Join 70M+ creators and sell, share & curate everything you do online. " <>
               "One bio link—your Linktree—brings it all together for your audience."
  end

  test "decodes named entities (incl. French accents and symbols)" do
    assert Entities.decode("CyberCit&eacute;") == "CyberCité"
    assert Entities.decode("Migration &amp; Conversion") == "Migration & Conversion"
    assert Entities.decode("Acero Marketing &#8211; Home") == "Acero Marketing – Home"
    assert Entities.decode("caf&eacute; &agrave; Paris") == "café à Paris"
    assert Entities.decode("100&euro; &middot; &copy;2026") == "100€ · ©2026"
  end

  test "decodes the exotic long tail (Greek, arrows, symbols)" do
    assert Entities.decode("&alpha;-&beta; testing") == "α-β testing"
    assert Entities.decode("price &rarr; checkout") == "price → checkout"
    assert Entities.decode("we &hearts; data &check;") == "we ♥ data ✓"
    assert Entities.decode("&sigma; &ne; &sigmaf;") == "σ ≠ ς"
  end

  test "decodes decimal and hex numeric references" do
    assert Entities.decode("L&#39;agence") == "L'agence"
    assert Entities.decode("L&#x27;agence") == "L'agence"
    assert Entities.decode("d&#039;intérim") == "d'intérim"
    assert Entities.decode("&#8364;50") == "€50"
    assert Entities.decode("&#x1F600;") == "😀"
  end

  test "is loss-free and idempotent" do
    # bare ampersand and unknown entities are left alone
    assert Entities.decode("Tom & Jerry") == "Tom & Jerry"
    assert Entities.decode("R&D budget") == "R&D budget"
    assert Entities.decode("&unknownentity;") == "&unknownentity;"

    once = Entities.decode("AT&amp;T &eacute; &#39;x&#39;")
    assert once == "AT&T é 'x'"
    assert Entities.decode(once) == once
  end

  test "decodes multiply-encoded source to a fixpoint" do
    assert Entities.decode("Credibility &amp;amp; Trust") == "Credibility & Trust"
    assert Entities.decode("a &amp;amp;amp; b") == "a & b"
    assert Entities.decode("L&amp;#39;agence") == "L'agence"
    assert Entities.decode("R&amp;D &amp;ndash; lab") == "R&D – lab"
  end

  test "rejects invalid/surrogate codepoints" do
    assert Entities.decode("&#xD800;") == "&#xD800;"
    assert Entities.decode("&#0;") == "&#0;"
    assert Entities.decode("&#999999999;") == "&#999999999;"
  end

  test "nil and non-binary input return empty string" do
    assert Entities.decode(nil) == ""
    assert Entities.decode(123) == ""
  end
end
