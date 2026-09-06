defmodule LS.Enrichment.ShopifyStore do
  @moduledoc """
  What kind of Shopify store is this? Read from the storefront HTML alone.

  Shopify prints a `window.Shopify` object on every storefront page with the
  theme (name, theme store id, role), the shop currency, locale and country,
  and the storefront exposes its localization form when Markets is on. None
  of it needs an API key, and all of it says something a merchant list
  buyer asks for: paid theme vs free theme, single-market vs multi-currency,
  Shopify Plus vs standard (2026-09-06).

  Pure functions over hostile HTML: nothing raises, everything is capped.
  """

  @type metadata :: %{
          shop_theme: String.t(),
          shop_theme_store_id: non_neg_integer() | nil,
          shop_currency: String.t(),
          shop_locales: non_neg_integer() | nil,
          shopify_plus: 0 | 1 | nil
        }

  @doc "Theme, currency, market breadth and Plus signal from a storefront page."
  @spec metadata(term()) :: metadata()
  def metadata(html) when is_binary(html) do
    h = binary_part(html, 0, min(byte_size(html), 600_000))

    %{
      shop_theme: theme_name(h),
      shop_theme_store_id: theme_store_id(h),
      shop_currency: currency(h),
      shop_locales: locales(h),
      shopify_plus: plus(h)
    }
  rescue
    _ -> empty()
  end

  def metadata(_), do: empty()

  @doc false
  def empty, do: %{shop_theme: "", shop_theme_store_id: nil, shop_currency: "", shop_locales: nil, shopify_plus: nil}

  # Shopify.theme = {"name":"Dawn","id":1234,"schema_name":"Dawn","schema_version":"15.0.0","theme_store_id":887,"role":"main"}
  defp theme_name(h) do
    case Regex.run(~r/Shopify\.theme\s*=\s*\{[^}]*?"name"\s*:\s*"([^"]{1,60})"/, h) do
      [_, name] -> name |> String.replace(["\t", "\n", "|"], " ") |> String.trim()
      _ -> ""
    end
  end

  defp theme_store_id(h) do
    case Regex.run(~r/"theme_store_id"\s*:\s*(\d{1,7})/, h) do
      [_, id] -> String.to_integer(id)
      _ -> nil
    end
  end

  defp currency(h) do
    case Regex.run(~r/Shopify\.currency\s*=\s*\{\s*"active"\s*:\s*"([A-Z]{3})"/, h) do
      [_, c] -> c
      _ ->
        case Regex.run(~r/"shopCurrency"\s*:\s*"([A-Z]{3})"|Shopify\.currency\.active\s*=\s*"([A-Z]{3})"/, h) do
          [_, c] -> c
          [_, "", c] -> c
          _ -> ""
        end
    end
  end

  # Markets: the localization form lists one <option> per selling locale and
  # the head carries one hreflang per published locale. Either works; take
  # the larger, capped.
  defp locales(h) do
    hreflang = Regex.scan(~r/<link[^>]+hreflang=["']([a-z]{2}(?:-[a-z]{2})?)["']/i, h) |> length()
    options = Regex.scan(~r/name=["']locale_code["'][^>]*>|<option[^>]+value=["'][a-z]{2}(?:-[A-Z]{2})?["'][^>]*data-locale/i, h) |> length()
    n = max(hreflang, options)
    if n > 0, do: min(n, 250), else: nil
  end

  # Plus stores are not labelled. Two things standard stores cannot have:
  # checkout on the shop's own domain (`/checkouts/` scripts without
  # `checkout.shopify.com`) shows up as a `Shopify.Checkout` config; and
  # `shopify-plus` appears in Shopify's own Plus-only script bundles. Absent
  # both, unknown (nil), never 0: we do not claim "not Plus".
  defp plus(h) do
    cond do
      String.contains?(h, "shopify-plus") or String.contains?(h, "Shopify Plus") -> 1
      Regex.match?(~r/"plus"\s*:\s*true/, h) -> 1
      true -> nil
    end
  end
end
