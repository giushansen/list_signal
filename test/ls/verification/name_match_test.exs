defmodule LS.Verification.NameMatchTest do
  use ExUnit.Case, async: true
  alias LS.Verification.NameMatch

  describe "key/1 — the name_country tier lives or dies on this being boring and exact" do
    test "strips legal forms from both ends, keeps the trade name" do
      assert NameMatch.key("Acme Widgets Ltd.") == "acmewidgets"
      assert NameMatch.key("ACME WIDGETS LIMITED") == "acmewidgets"
      assert NameMatch.key("SARL Les Éditions Dupont") == "leseditionsdupont"
      assert NameMatch.key("The Coca-Cola Company") == "cocacola"
      assert NameMatch.key("Nestlé S.A.") == "nestle"
      assert NameMatch.key("Müller GmbH & Co. KG") == "muller"
      assert NameMatch.key("Dupont et Cie") == "dupont"
    end

    test "keeps words that domains keep (Group, Holdings, Services)" do
      assert NameMatch.key("Acme Group plc") == "acmegroup"
      assert NameMatch.key("Beta Holdings Inc") == "betaholdings"
    end

    test "'&' becomes 'and' — marksandspencer.com, not marksspencer" do
      assert NameMatch.key("Marks & Spencer plc") == "marksandspencer"
    end

    test "legal-form words inside a name are NOT stripped" do
      assert NameMatch.key("Company Store Ltd") == "companystore"
      assert NameMatch.key("Co-operative Bank plc") == "cooperativebank"
    end

    test "hostile input: nil, empty, non-binary, control characters, oversized" do
      assert NameMatch.key(nil) == ""
      assert NameMatch.key("") == ""
      assert NameMatch.key(42) == ""
      assert NameMatch.key("Acme\x00Widgets\tLtd\n") == "acmewidgets"
      long = String.duplicate("a", 10_000)
      key = NameMatch.key(long <> " Ltd")
      assert String.length(key) <= 500
    end
  end

  test "usable?/1 refuses short keys — 'abc' would link to abc.co.uk and be wrong" do
    refute NameMatch.usable?("abc")
    refute NameMatch.usable?("")
    refute NameMatch.usable?(nil)
    assert NameMatch.usable?("acmewidgets")
  end
end
