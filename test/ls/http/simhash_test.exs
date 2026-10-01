defmodule LS.HTTP.SimhashTest do
  @moduledoc """
  The text fingerprint behind template detection (2026-10-01). Two pages
  from one template must land a few bits apart; two unrelated pages far
  apart; too little text gives 0 so an empty shell never clusters with
  anything.
  """
  use ExUnit.Case, async: true

  import Bitwise
  alias LS.HTTP.Simhash

  @parked_a "This domain is for sale. Buy this domain today and start your business. Contact the broker for pricing and transfer details."
  @parked_b "This domain is for sale. Buy this domain today and start your project. Contact the broker for pricing and transfer details."
  @shop "Handmade ceramic mugs and bowls from our studio in Lisbon. Free shipping over 60 euros. New autumn collection now in stock."

  test "near-identical texts hash within a few bits, unrelated texts far apart" do
    a = Simhash.of(@parked_a)
    b = Simhash.of(@parked_b)
    c = Simhash.of(@shop)
    # One word swapped touches three of the twenty-odd shingles.
    assert Simhash.distance(a, b) <= 12
    assert Simhash.distance(a, c) >= 20
    assert Simhash.distance(a, b) < Simhash.distance(a, c)
  end

  test "the hash is stable, 64-bit and order-of-blocks aware only through content" do
    assert Simhash.of(@shop) == Simhash.of(@shop)
    assert Simhash.of(["Handmade ceramic mugs and bowls", "from our studio in Lisbon."]) == Simhash.of("Handmade ceramic mugs and bowls from our studio in Lisbon.")
    assert Simhash.of(@shop) < 1 <<< 64
  end

  test "too little text is 0, hostile input never raises" do
    assert Simhash.of("") == 0
    assert Simhash.of("two words") == 0
    assert Simhash.of(nil) == 0
    assert Simhash.of([nil, 42, ""]) == 0
    assert Simhash.of(<<0xFF, 0xFE, "abc def ghi">>) != 0
  end

end
