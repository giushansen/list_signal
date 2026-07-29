defmodule LS.Enrichment.PricePointsTest do
  @moduledoc """
  Pricing extraction records *observed price points*, not named plan tiers.

  An earlier version emitted `plan_1..plan_N`, where the label was purely the
  sort index — it read as meaningful data while carrying none. These tests pin
  the honest shape: a currency, a number, nothing invented.
  """
  use ExUnit.Case, async: true

  alias LS.Enrichment.Agent

  describe "price_points/2" do
    test "records the currency rather than assuming dollars" do
      html = "<p>From $29/mo</p><p>Europe: €25</p><p>UK: £22</p>"
      rows = Agent.price_points(html, "acme.com")

      assert Enum.sort(Enum.map(rows, &{&1.currency, &1.price})) ==
               [{"EUR", 25.0}, {"GBP", 22.0}, {"USD", 29.0}]
    end

    test "invents no plan names — a row is a price, nothing more" do
      [row | _] = Agent.price_points("<p>$29</p>", "acme.com")

      assert Map.keys(row) |> Enum.sort() == [:currency, :domain, :price, :seen_at]
      refute Map.has_key?(row, :plan_name)
    end

    test "ignores currency amounts inside <script> — the old noise source" do
      # Analytics/product-feed JSON sits next to real copy and is full of bare
      # numbers. Including it produced ladders like 1|2|6|8|20|21|22 for vendors
      # that publish no self-serve pricing at all.
      html = """
      <script>var cfg = {price: "$1", tiers: ["$2","$6","$8","$20","$21"]};</script>
      <style>.badge:after { content: "$99"; }</style>
      <h2>Pricing</h2><div>Pro — $49/month</div>
      """

      assert [%{price: 49.0, currency: "USD"}] = Agent.price_points(html, "acme.com")
    end

    test "sorts ascending so the list reads as a price ladder" do
      html = "<p>$99</p><p>$9</p><p>$29</p>"
      assert Enum.map(Agent.price_points(html, "acme.com"), & &1.price) == [9.0, 29.0, 99.0]
    end

    test "dedupes a price repeated across the page" do
      html = "<p>$29</p><p>only $29 per seat</p><p>$29</p>"
      assert length(Agent.price_points(html, "acme.com")) == 1
    end

    test "caps at 12 so one pathological page cannot flood the table" do
      html = Enum.map_join(1..40, " ", &"<p>$#{&1}</p>")
      assert length(Agent.price_points(html, "acme.com")) == 12
    end

    test "drops zero and implausibly large amounts" do
      html = "<p>$0</p><p>$250000</p><p>$45</p>"
      assert Enum.map(Agent.price_points(html, "acme.com"), & &1.price) == [45.0]
    end

    test "reads a large amount in full instead of truncating it to a fake price" do
      # `\d{1,3}(?:[.,]\d{3})*` matched only `250` of `$250000` and recorded a
      # $250 price that was never on the page.
      assert Agent.price_points("<p>$250000</p>", "acme.com") == []
      assert [%{price: 1500.0}] = Agent.price_points("<p>$1500</p>", "acme.com")
    end

    test "handles separators and decimals" do
      html = "<p>$1,234.56</p><p>$2,000</p><p>$19.99</p>"
      assert Enum.map(Agent.price_points(html, "acme.com"), & &1.price) == [19.99, 1234.56, 2000.0]
    end

    test "a page with no prices yields no rows rather than a placeholder" do
      assert Agent.price_points("<h1>About us</h1>", "acme.com") == []
    end
  end
end
