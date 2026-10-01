defmodule LS.Tech.CatalogTest do
  @moduledoc """
  The tech catalog is the closed list the product publishes (2026-10-01).
  Production carried 7,304 distinct "apps", 6,262 of them humanised Shopify
  handles on fewer than 100 stores. These pin that only catalog names pass,
  that aliases land on a real entry, and that the names the detectors and
  the data-contract tests rely on are present.
  """
  use ExUnit.Case, async: true

  alias LS.Tech.Catalog

  test "names are unique and non-empty" do
    names = Catalog.names()
    assert names == Enum.uniq(names)
    refute Enum.any?(names, &(&1 == ""))
  end

  test "every alias resolves to a published name" do
    for {from, to} <- Catalog.aliases() do
      assert Catalog.known?(to), "alias #{from} -> #{to}, but #{to} is not in the catalog"
      refute Catalog.known?(from), "alias #{from} is itself a catalog name; pick one spelling"
    end
  end

  test "publish/1 canonicalises, drops unknown handles and keeps order" do
    assert Catalog.publish(["Judgeme", "Shopify", "Notify Me Ninja Htn", "Klaviyo Email Marketing", "Shopify"]) ==
             ["Judge.me", "Shopify", "Klaviyo"]

    assert Catalog.publish([]) == []
    assert Catalog.publish(["Xb Quote Request", "2026 09 22 08 46 47 Utc", "Frontend"]) == []
  end

  test "the names other code depends on are present" do
    for name <- ["Shopify", "WordPress", "WooCommerce", "Klaviyo", "HubSpot", "Google Workspace", "Microsoft 365", "Cloudflare", "Elementor", "Yoast SEO", "Judge.me", "Open Graph", "Google Fonts"] do
      assert Catalog.known?(name), "#{name} missing from the catalog"
    end
  end

  test "ecosystem add-ons are listed and general vendors are not" do
    apps = Catalog.app_names()
    assert "Judge.me" in apps
    assert "Elementor" in apps
    refute "Klaviyo" in apps
    refute "Shopify" in apps
    assert "Judge.me" in Catalog.names_in("shopify")
    assert "Yoast SEO" in Catalog.names_in("wordpress")
  end

  test "every entry has a category and the table rows are strings" do
    for {name, cat, eco} <- Catalog.entries() do
      assert is_atom(cat) and cat != nil, name
      assert is_binary(eco)
    end

    assert {"Shopify", "platform", ""} in Catalog.table_rows()
  end

  test "alias arrays are parallel and sorted for ClickHouse transform()" do
    {from, to} = Catalog.alias_arrays()
    assert length(from) == length(to)
    assert from == Enum.sort(from)
  end
end
