defmodule LSWeb.ExplorerDepthToolbarTest do
  @moduledoc """
  The depth row on /dashboard is always on screen, and only the controls
  that fit the chosen business type are on it.

  Why this is pinned (2026-09-06): the row used to be hidden until a business
  model or tech was picked, so "Hiring" and "SEO", the two depth filters that
  apply to every business, were unreachable from a fresh page and the owner
  asked for them back. The type-specific controls stay gated: a catalogue
  filter shown to someone searching SaaS is noise; a pricing-page filter in a
  Shopify search matches nothing meaningful.

  A hidden control must not keep filtering. A "min products 10" left over from
  a Shopify search would silently empty a SaaS list with nothing on screen to
  explain the count, so switching type blanks the controls that went away.
  """
  use ExUnit.Case, async: true

  alias LSWeb.ExplorerLive

  @base %{business_model: "", tech: "", has_email: "", hiring: "", has_pricing: "",
          has_catalog: "", min_products: "", max_products: "", min_price_avg: "",
          max_price_avg: "", min_seo_score: "", max_seo_score: ""}

  describe "which controls the toolbar shows" do
    test "a fresh page still gets the depth row: email, hiring and SEO apply to every business" do
      assert ExplorerLive.filter_shape(@base) == :base
    end

    test "a business type that is neither commerce nor SaaS gets the base row only" do
      assert ExplorerLive.filter_shape(%{@base | business_model: "Agency"}) == :base
      assert ExplorerLive.filter_shape(%{@base | tech: "WordPress"}) == :base
    end

    test "catalogue and price controls appear only once a commerce model or platform is chosen" do
      assert ExplorerLive.filter_shape(%{@base | business_model: "Shopify"}) == :commerce
      assert ExplorerLive.filter_shape(%{@base | business_model: "Ecommerce"}) == :commerce
      assert ExplorerLive.filter_shape(%{@base | tech: "WooCommerce"}) == :commerce
      assert ExplorerLive.filter_shape(%{@base | tech: "Magento,Cloudflare"}) == :commerce
    end

    test "published-pricing control appears only for SaaS-shaped models" do
      assert ExplorerLive.filter_shape(%{@base | business_model: "SaaS"}) == :saas
      assert ExplorerLive.filter_shape(%{@base | business_model: "Marketplace"}) == :saas
    end

    test "a depth filter alone does not unlock the type-specific controls" do
      # The old :any shape did exactly this: setting has_email surfaced the
      # catalogue inputs with no commerce model chosen.
      assert ExplorerLive.filter_shape(%{@base | has_email: "true", min_seo_score: "10"}) == :base
    end

    test "hostile filter values do not crash the shape decision" do
      assert ExplorerLive.filter_shape(%{@base | business_model: nil}) == :base
      assert ExplorerLive.filter_shape(%{}) == :base
      assert ExplorerLive.filter_shape(%{@base | business_model: String.duplicate("x", 10_000)}) == :base
      assert ExplorerLive.filter_shape(%{@base | tech: " shopify "}) == :commerce
    end
  end

  describe "a control that is not on screen does not keep filtering" do
    test "leaving Shopify for SaaS drops the catalogue and price filters" do
      left =
        %{@base | business_model: "Shopify", min_products: "10", max_price_avg: "500",
                  has_catalog: "true", has_email: "true", min_seo_score: "40"}
        |> Map.put(:business_model, "SaaS")
        |> ExplorerLive.prune_hidden_depth()

      assert left.min_products == ""
      assert left.max_price_avg == ""
      assert left.has_catalog == ""
      # The base row survives the switch.
      assert left.has_email == "true"
      assert left.min_seo_score == "40"
    end

    test "leaving SaaS for Shopify drops the pricing filter" do
      left =
        %{@base | business_model: "Shopify", has_pricing: "true", hiring: "true"}
        |> ExplorerLive.prune_hidden_depth()

      assert left.has_pricing == ""
      assert left.hiring == "true"
    end

    test "clearing the business model drops every type-specific filter" do
      left =
        %{@base | min_products: "10", has_pricing: "true", has_email: "true"}
        |> ExplorerLive.prune_hidden_depth()

      assert left.min_products == ""
      assert left.has_pricing == ""
      assert left.has_email == "true"
    end

    test "a shape whose controls are all on screen is left untouched" do
      shopify = %{@base | business_model: "Shopify", min_products: "10", has_catalog: "true"}
      assert ExplorerLive.prune_hidden_depth(shopify) == shopify

      saas = %{@base | business_model: "SaaS", has_pricing: "true"}
      assert ExplorerLive.prune_hidden_depth(saas) == saas
    end

    test "every one-click segment is consistent with its own toolbar" do
      # A preset that set a filter its own row hides would show a count the
      # user cannot explain or clear from the toolbar.
      for seg <- ExplorerLive.segments() do
        filters = Map.merge(@base, seg.filters)
        assert ExplorerLive.prune_hidden_depth(filters) == filters,
               "segment #{seg.id} sets a depth filter its toolbar shape hides"
      end
    end
  end
end
