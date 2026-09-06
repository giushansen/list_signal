defmodule LS.HTTP.AppDetectorTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.AppDetector

  @moduledoc """
  Shopify app detection beyond the signature list (2026-09-06). Theme app
  extensions put the app's own handle in every asset URL, so one regex sees
  the long tail the 135-domain signature list never will; app proxies name
  storefront-served app pages; HubSpot's hub loaders name the hubs a
  customer pays for. Third-party HTML is hostile: nothing may raise, and
  every list is capped.
  """

  @page """
  <script src="https://cdn.shopify.com/extensions/1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d/judgeme-core-3.1.0/assets/judgeme.js"></script>
  <script src="https://cdn.shopify.com/extensions/2b3c4d5e-6f70-4b8c-9d0e-1f2a3b4c5d6e/klaviyo-onsite-12.2/assets/onsite.js"></script>
  <link href="https://cdn.shopify.com/extensions/9f8e7d6c-5b4a-4392-8170-6f5e4d3c2b1a/shopify-1.0.0/assets/x.css">
  <a href="/apps/wishlist">Wishlist</a> <a href="/a/rewards">Rewards</a> <a href="/tools/size-chart">Sizes</a>
  <script src="//js.hs-scripts.com/1234567.js"></script>
  <script src="https://js.hsforms.net/forms/embed/v2.js"></script>
  <script>window.HubSpotConversations = {};</script>
  """

  test "extension handles are read from asset URLs and humanised" do
    assert AppDetector.extension_handles(@page) == ["judgeme-core", "klaviyo-onsite"]
    apps = AppDetector.detect(@page).apps
    assert "Judgeme Core" in apps
    assert "Klaviyo Onsite" in apps
    refute "Shopify" in apps, "Shopify's own runtime bundles are not merchant apps"
  end

  test "app proxies name the storefront-served app pages" do
    assert AppDetector.app_proxy_paths(@page) == ["wishlist", "rewards", "size-chart"]
    apps = AppDetector.detect(@page).apps
    assert "Wishlist App Proxy" in apps
    assert "Loyalty App Proxy" in apps
    assert "Size Chart App Proxy" in apps
  end

  test "HubSpot hubs are detected from their loaders" do
    apps = AppDetector.detect(@page).apps
    assert "HubSpot Tracking" in apps
    assert "HubSpot Forms" in apps
    assert "HubSpot Chat" in apps
    refute "HubSpot Meetings" in apps
  end

  test "the signature list still works alongside" do
    apps = AppDetector.detect(~s(<script src="https://static.klaviyo.com/onsite/js/klaviyo.js">)).apps
    assert "Klaviyo" in apps
  end

  test "hostile pages never raise and lists are capped" do
    assert AppDetector.detect(nil).apps == []
    assert AppDetector.detect(<<255, 0, 1>>).apps == []
    many = Enum.map_join(1..500, "\n", &~s(<script src="https://cdn.shopify.com/extensions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/app-#{&1}-1.0/assets/a.js">))
    assert length(AppDetector.extension_handles(many)) <= 100
    assert AppDetector.extension_handles(String.duplicate("cdn.shopify.com/extensions/", 100_000)) == []
    links = Enum.map_join(1..500, "", &~s(<a href="/apps/p#{&1}">))
    assert length(AppDetector.app_proxy_paths(links)) <= 50
  end
end
