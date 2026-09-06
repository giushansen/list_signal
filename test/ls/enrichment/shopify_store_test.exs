defmodule LS.Enrichment.ShopifyStoreTest do
  use ExUnit.Case, async: true

  alias LS.Enrichment.ShopifyStore

  @moduledoc "What kind of Shopify store: theme, currency, markets, Plus (2026-09-06). Pure over hostile HTML."

  @html """
  <link rel="alternate" hreflang="en" href="https://x.com/"><link rel="alternate" hreflang="fr" href="https://x.com/fr">
  <link rel="alternate" hreflang="de-de" href="https://x.com/de">
  <script>window.Shopify = window.Shopify || {}; Shopify.shop = "x.myshopify.com";
  Shopify.theme = {"name":"Impulse","id":123,"schema_name":"Impulse","schema_version":"7.4.0","theme_store_id":857,"role":"main"};
  Shopify.currency = {"active":"EUR","rate":"1.0"};</script>
  """

  test "reads theme, theme store id, currency and market breadth" do
    m = ShopifyStore.metadata(@html)
    assert m.shop_theme == "Impulse"
    assert m.shop_theme_store_id == 857
    assert m.shop_currency == "EUR"
    assert m.shop_locales == 3
    assert m.shopify_plus == nil, "absent evidence is unknown, never a claim of not-Plus"
  end

  test "Plus is only claimed on evidence" do
    assert ShopifyStore.metadata(@html <> ~s(<script src="/cdn/shopify-plus/x.js">)).shopify_plus == 1
  end

  test "a non-Shopify or hostile page yields the empty shape" do
    assert ShopifyStore.metadata("<html></html>") == ShopifyStore.empty()
    assert ShopifyStore.metadata(nil) == ShopifyStore.empty()
    assert ShopifyStore.metadata(<<255, 1>>) == ShopifyStore.empty()
    huge = ShopifyStore.metadata("Shopify.theme = {\"name\":\"" <> String.duplicate("a", 10_000) <> "\"}")
    assert huge.shop_theme == ""
    refute ShopifyStore.metadata("Shopify.theme = {\"name\":\"a|b\tc\"}").shop_theme =~ ~r/[|\t]/
  end
end
