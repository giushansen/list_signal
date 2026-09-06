defmodule LS.ML.FeaturesTest do
  use ExUnit.Case, async: true

  alias LS.ML.Features

  @moduledoc """
  The hint sentence appended to the classifier's text (2026-09-06). It must
  be identical at training and at runtime, tiny in vocabulary, and immune
  to hostile row values, or the head is trained on one shape and served
  another.
  """

  test "renders platform, apps, mail, catalog, jobs and pages in a stable vocabulary" do
    row = %{http_tech: "Cloudflare|Shopify|React", http_apps: "Klaviyo|Judge.me", dns_mx: "10:aspmx.l.google.com",
            dns_dmarc: "reject", product_count: 540, job_count: 3, sitemap_urls: 12_000, dns_ms_enterprise: "", dns_bimi: ""}

    assert Features.hint(row) ==
             "hints: platform Cloudflare, Shopify, React; apps Klaviyo, Judge.me; mail google workspace dmarc reject; products hundreds; jobs few; pages tens of thousands"
  end

  test "string keys (ClickHouse rows) work the same as atom keys" do
    assert Features.hint(%{"http_tech" => "Shopify", "product_count" => "40"}) == "hints: platform Shopify"
    assert Features.hint(%{"http_tech" => "Shopify", "product_count" => 40}) == "hints: platform Shopify; products dozens"
  end

  test "an empty row yields no hint and the text is untouched" do
    assert Features.hint(%{}) == ""
    assert Features.text_with_hint("  Acme Inc  ", %{}) == "Acme Inc"
    assert Features.text_with_hint("Acme", %{http_tech: "Shopify"}) == "Acme hints: platform Shopify"
  end

  test "hostile values never raise and lists are capped" do
    assert Features.hint(nil) == ""
    assert Features.hint(%{http_tech: <<255, 0>>, http_apps: 42, product_count: -5, dns_mx: nil, sitemap_urls: "x"}) |> is_binary()
    many = Enum.map_join(1..200, "|", &"App#{&1}")
    assert length(String.split(Features.hint(%{http_apps: many}), ",")) <= 6
    assert Features.text_with_hint(nil, %{}) == ""
  end
end
