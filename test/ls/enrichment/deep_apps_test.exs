defmodule LS.Enrichment.DeepAppsTest do
  use ExUnit.Case, async: true

  alias LS.Enrichment.Agent

  @moduledoc """
  Apps beyond the homepage (2026-09-06): the depth pass scans every page it
  already fetched plus one product page for Shopify stores, and reads the
  store shape from window.Shopify. Pinned here because the product-page
  fetch takes third-party data (the product handle) into a request path.
  """

  test "apps are unioned across the pages already held, without any fetch" do
    home = %{html: ~s(<script src="https://js.hsforms.net/forms/embed/v2.js"></script>Shopify.theme = {"name":"Dawn","theme_store_id":887}; Shopify.currency = {"active":"USD"})}
    visited = [{:contact, %{html: ~s(<script src="https://static.klaviyo.com/onsite/js/klaviyo.js">)}}]

    deep = Agent.deep_apps("example.com", nil, home, visited, %{products: []})

    assert deep.apps_deep =~ "HubSpot Forms"
    assert deep.apps_deep =~ "Klaviyo"
    assert deep.shop_theme == "Dawn"
    assert deep.shop_theme_store_id == 887
    assert deep.shop_currency == "USD"
  end

  test "a hostile product handle is never turned into a request" do
    # With a nil ip Client.fetch refuses before any network; a bad handle must
    # not even get that far, so the result is the same as having no product.
    home = %{html: ""}
    bad = %{products: [%{handle: "../../etc/passwd?x=<script>"}]}
    assert Agent.deep_apps("example.com", nil, home, [], bad).apps_deep == ""
    assert File.read!("lib/ls/enrichment/agent.ex") =~ "Regex.match?(~r/^[a-z0-9][a-z0-9._-]{0,120}$/, h)"
  end

  test "a page that is not HTML, or missing, yields the empty shape" do
    deep = Agent.deep_apps("example.com", nil, %{html: nil}, [{:legal, %{}}], %{})
    assert deep.apps_deep == ""
    assert deep.shop_theme == ""
    assert deep.shopify_plus == nil
  end
end
