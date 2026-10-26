defmodule LS.PipelineSecondaryPlanTest do
  @moduledoc """
  2026-10-26: the two secondary fetches went to the login and pricing
  pages for tech, so a Shopify store spent them on /products and /checkout
  and nobody read /pages/contact or /pages/about-us. The first slot is now
  the page most likely to carry the business's own address; the budget is
  unchanged at two.
  """
  use ExUnit.Case, async: true

  alias LS.Pipeline
  alias LS.HTTP.PageExtractor

  test "a Shopify store reads its contact page first, then a policy page if one is linked" do
    pages = "/products/mug|/collections/all|/pages/contact|/pages/about-us|/policies/privacy-policy|/account/login|/checkout"
    assert Pipeline.secondary_plan(["Shopify", "Klaviyo"], pages) == [contact: "/pages/contact", policy: "/policies/privacy-policy"]
  end

  test "a store with no contact page falls back to about; login and checkout are never chosen for it" do
    assert Pipeline.secondary_plan("Shopify|Judge.me", "/pages/about-us|/account/login|/products/x") == [about: "/pages/about-us"]
  end

  test "an agency or SaaS site reads imprint or contact first and pricing or login second" do
    assert Pipeline.secondary_plan(["WordPress"], "/pricing|/contact|/login|/blog") == [contact: "/contact", pricing: "/pricing"]
    assert Pipeline.secondary_plan(["Next.js"], "/impressum|/kontakt|/login") == [legal: "/impressum", login: "/login"]
    assert Pipeline.secondary_plan([], "/team|/pricing") == [about: "/team", pricing: "/pricing"]
  end

  test "never more than two, never the same path twice, and nothing when nothing is linked" do
    assert Pipeline.secondary_plan([], "") == []
    assert Pipeline.secondary_plan(nil, nil) == []
    assert Pipeline.secondary_plan(["Shopify"], "/products/a|/products/b") == []
    assert length(Pipeline.secondary_plan([], "/contact|/about|/pricing|/login|/careers")) == 2
  end

  test "the Shopify paths are recognised as contact, about and policy kinds" do
    assert PageExtractor.page_kind("/pages/contact") == :contact
    assert PageExtractor.page_kind("/pages/contact-us") == :contact
    assert PageExtractor.page_kind("/pages/about-us") == :about
    assert PageExtractor.page_kind("/policies/privacy-policy") == :policy
    assert PageExtractor.page_kind("/policies/contact-information") == :policy
    assert PageExtractor.page_kind("/products/mug") == nil
    refute PageExtractor.page_kind("/checkout") in [:contact, :about, :policy]
  end

  test "a store homepage records its contact and policy links in http_pages" do
    html = ~s(<a href="/products/mug">Mug</a><a href="/pages/contact">Contact</a><a href="/policies/refund-policy">Refunds</a><a href="/checkout">Checkout</a>)
    {pages, _} = PageExtractor.extract_all(html, "store.example")
    assert pages =~ "/pages/contact"
    assert pages =~ "/policies/refund-policy"
  end

  test "form placeholders and input values are not addresses" do
    html = ~s(<form><input type="email" placeholder="name@company.com"><input value="john@mydomain.com"></form><p>Write to hello@store.com</p>)
    {_, emails} = PageExtractor.extract_all(html, "store.com")
    assert emails == "hello@store.com"
  end

  test "contact rows carry the page and whether the address is on the domain" do
    rows = Pipeline.contact_rows(["hello@store.example", "owner@gmail.com"], "store.example", "contact")
    assert rows == [
             %{email: "hello@store.example", source_page: "contact", on_domain: 1, kind: "role"},
             %{email: "owner@gmail.com", source_page: "contact", on_domain: 0, kind: "free_mail"}
           ]
    assert Pipeline.contact_rows(nil, "x", "y") == []
  end
end
