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

  test "the depth estimate reads the queue's discovery row plus what the pass learned" do
    item = %{domain: "example.com", http_tech: "Shopify", est: %{domain: "example.com", tranco_rank: 40_000, majestic_rank: 30_000, majestic_ref_subnets: 600,
             rdap_registrar: "GoDaddy.com, LLC", ctl_issuer: "R3", dns_mx: "10:aspmx.l.google.com", http_tech: "Shopify|Cloudflare", http_apps: "Klaviyo", http_status: 200}}
    d = Agent.depth_estimate(item, %{apps_deep: "Judge.me|Klaviyo", product_count: 2_500, job_count: 25, sitemap_urls: 8_000})
    assert d.depth_estimated_revenue != ""
    assert d.depth_revenue_evidence =~ "catalog:2500_products"
    assert d.depth_revenue_evidence =~ "sitemap:8000_urls"
    assert d.depth_revenue_evidence =~ "hiring:25_jobs"
    assert is_float(d.depth_revenue_confidence)
  end

  test "an item without a discovery row, or hostile summary values, never raises" do
    assert %{depth_estimated_revenue: r} = Agent.depth_estimate(%{domain: "x.example"}, %{})
    assert is_binary(r)
    assert %{depth_revenue_confidence: nil} = Agent.depth_estimate(%{domain: "x.example"}, %{product_count: "boom", apps_deep: 42})
  end

  test "the queue carries every column the estimator reads, in the order the row mapping expects" do
    src = File.read!("lib/ls/clickhouse.ex")
    cols = LS.Clickhouse.estimator_columns()
    assert length(cols) == 27
    for c <- cols, do: assert(src =~ "b.#{c}", "#{c} missing from businesses_needing_enrichment")
    assert src =~ "[d, pages, tech, blocked, status, country, tier | est]"
  end

  test "a page that is not HTML, or missing, yields the empty shape" do
    deep = Agent.deep_apps("example.com", nil, %{html: nil}, [{:legal, %{}}], %{})
    assert deep.apps_deep == ""
    assert deep.shop_theme == ""
    assert deep.shopify_plus == nil
  end
end
