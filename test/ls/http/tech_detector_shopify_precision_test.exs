defmodule LS.HTTP.TechDetectorShopifyPrecisionTest do
  @moduledoc """
  2026-10-26: browserstack.com, which documents Shopify testing, was listed
  as a Shopify store because the detector matched the words
  "cdn.shopify.com" and "shopify.theme" anywhere in the page. Shopify is
  now a store's own asset URL, section markup or runtime object, never prose.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.TechDetector

  defp detect(body), do: TechDetector.detect(%{body: body, headers: [], status: 200}).tech

  test "a real store is detected from its asset URL, section markup or runtime object" do
    assert "Shopify" in detect(~s(<link rel="stylesheet" href="https://cdn.shopify.com/s/files/1/0123/theme.css"><div id="shopify-section-header"></div>))
    assert "Shopify" in detect(~s(<script src="https://cdn.shopify.com/shopifycloud/shopify/assets/storefront/load_feature.js"></script>))
    assert "Shopify" in detect(~s(<script>window.ShopifyAnalytics = window.ShopifyAnalytics || {}; Shopify.theme = {"name":"Dawn"};</script>))
    assert "Shopify" in detect(~s(<div class="shopify-section"><p>Hi</p></div>))
  end

  test "a page that merely talks about Shopify is not a store" do
    body = """
    <html><body><h1>Test your Shopify store on real devices</h1>
    <p>Load scripts from cdn.shopify.com and inspect Shopify.theme in the console. Our docs cover shopify-section layouts.</p>
    <pre>const url = "https://cdn.shopify.com/example"; console.log(Shopify.theme);</pre>
    </body></html>
    """
    refute "Shopify" in detect(body)
  end

  test "the x-shopid header still settles it" do
    assert "Shopify" in TechDetector.detect(%{body: "<html></html>", headers: [{"x-shopid", "123"}], status: 200}).tech
  end
end
