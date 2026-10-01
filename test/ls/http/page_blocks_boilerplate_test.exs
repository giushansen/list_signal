defmodule LS.HTTP.PageBlocksBoilerplateTest do
  @moduledoc """
  The body keeps what is about the business (2026-10-01): a menu repeated
  in the body (a <ul> outside <nav>) and a consent banner are dropped, a
  heading that happens to match a menu label is kept, category lists stay.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.PageBlocks

  @html """
  <html><body>
  <header><nav><a href="/">Home</a><a href="/contact">Contact</a><a href="/shop">Shop</a></nav></header>
  <main>
    <ul><li>Home</li><li>Contact</li><li>Shop</li></ul>
    <h1>Shop</h1>
    <p>We use cookies to improve your experience. Accept all or reject all.</p>
    <p>Handmade ceramics from our studio in Lisbon since 2012.</p>
    <ul><li>Mugs</li><li>Bowls</li><li>Vases</li></ul>
  </main>
  <footer><p>Privacy Policy</p><p>Contact</p></footer>
  </body></html>
  """

  test "menu repeats and consent text leave the body, the heading and the categories stay" do
    parts = PageBlocks.extract(@html)
    texts = Enum.map(parts.body, &elem(&1, 1))
    refute "Home" in texts
    refute Enum.any?(texts, &(&1 =~ "cookies"))
    assert "Shop" in texts, "the h1 survives even though a menu label matches"
    assert Enum.count(texts, &(&1 == "Shop")) == 1
    assert "Mugs" in texts and "Vases" in texts
    assert Enum.any?(texts, &(&1 =~ "Handmade ceramics"))
  end
end
