defmodule LSWeb.SitemapController do
  @moduledoc "XML sitemaps (index + shards) for the public SEO surface."
  use LSWeb, :controller

  # /compare/:slug renders for any "a-vs-b" pair, but the sitemap never listed a
  # single one — so Google only ever found /compare/klaviyo-vs-mailchimp (via a
  # backlink), and it is already the #2 page on the site by impressions. These are
  # curated real competitor pairs rather than every combination of the top techs:
  # a combinatorial dump would be thin content and risks a quality penalty.
  #
  # Names must match `http_tech` exactly — they are filtered against the live tech
  # directory below, so a rename upstream drops the URL instead of emitting a 404.
  @compare_pairs [
    # email / SMS / CRM
    {"Klaviyo", "Mailchimp"},
    {"Klaviyo", "Attentive"},
    {"Klaviyo", "HubSpot"},
    {"Mailchimp", "HubSpot"},
    # support / live chat
    {"Gorgias", "Zendesk"},
    {"Gorgias", "Tidio"},
    {"Tidio", "Zendesk"},
    {"Tidio", "Tawk.to"},
    {"Tawk.to", "Zendesk"},
    # analytics / tagging
    {"Google Analytics", "Matomo"},
    {"Google Tag Manager", "Google Analytics"},
    {"Meta Pixel", "Google Tag Manager"},
    # payments
    {"Stripe", "PayPal"},
    {"Afterpay", "PayPal"},
    {"Stripe", "Afterpay"},
    # platforms
    {"Shopify", "WooCommerce"},
    {"WooCommerce", "WordPress"},
    {"Webflow", "WordPress"},
    {"Shopify", "Webflow"},
    # frontend
    {"Vue.js", "Svelte"},
    {"Next.js", "Svelte"},
    {"Vue.js", "AngularJS"},
    {"jQuery", "Vue.js"},
    {"Alpine.js", "Vue.js"},
    # servers / hosting
    {"Nginx", "Apache"},
    {"Nginx", "LiteSpeed"},
    {"Apache", "LiteSpeed"},
    {"OpenResty", "Nginx"},
    {"Cloudflare", "Vercel"},
    # asset CDNs
    {"cdnjs", "jsDelivr"},
    {"jsDelivr", "unpkg"},
    {"cdnjs", "unpkg"},
    # fonts / carousels / animation / video / consent
    {"Google Fonts", "Adobe Fonts"},
    {"Swiper", "Slick"},
    {"Swiper", "Owl Carousel"},
    {"Slick", "Owl Carousel"},
    {"GSAP", "AOS"},
    {"YouTube", "Vimeo"},
    {"Cookiebot", "UserWay"}
  ]

  def index(conn, _params) do
    base = "https://listsignal.com"

    stores = case LS.Clickhouse.all_shopify_domains(10_000) do
      {:ok, rows} -> Enum.map(rows, fn [d] -> entry(base, "/shopify/" <> String.replace(d, ".", "-"), "0.6", "weekly") end)
      _ -> []
    end

    # /tech/* covers every tracked technology (those pages span all sites),
    # but /top/shopify-stores-using-* only exists where Shopify stores
    # actually use the tech — emitting the rest advertised 404s to Google.
    # Cached 6h: the underlying arrayJoin walks the full domains table, and
    # paying that on every CDN cache-miss of the sitemap is a 10s response
    # plus a multi-GB scan on the shared box. The tech->Shopify intersection
    # drifts far slower than the cache expires.
    shopify_techs =
      LS.UICache.fetch(:sitemap_shopify_techs, 21_600, fn ->
        case LS.Clickhouse.shopify_tech_names() do
          {:ok, rows} -> MapSet.new(rows, fn [name | _] -> name end)
          _ -> MapSet.new()
        end
      end)

    techs = case LS.Clickhouse.all_tech_slugs() do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
          tech_page = [entry(base, "/tech/" <> slug, "0.7", "weekly")]

          if MapSet.member?(shopify_techs, name) do
            tech_page ++ [entry(base, "/top/shopify-stores-using-" <> slug, "0.6", "weekly")]
          else
            tech_page
          end
        end)
      _ -> []
    end

    countries = case LS.Clickhouse.country_directory() do
      {:ok, rows} -> Enum.map(rows, fn [code, _] -> entry(base, "/top/shopify-stores-" <> String.downcase(code), "0.6", "weekly") end)
      _ -> []
    end

    compares = case LS.Clickhouse.tech_directory_cached() do
      {:ok, rows} ->
        known = MapSet.new(rows, fn [name | _] -> name end)

        @compare_pairs
        |> Enum.filter(fn {a, b} -> MapSet.member?(known, a) and MapSet.member?(known, b) end)
        |> Enum.map(fn {a, b} ->
          slug = LS.Clickhouse.tech_slug(a) <> "-vs-" <> LS.Clickhouse.tech_slug(b)
          entry(base, "/compare/" <> slug, "0.8", "weekly")
        end)

      _ -> []
    end

    marketing = [
      entry(base, "/", "1.0", "daily"),
      entry(base, "/pricing", "0.8", "weekly"),
      entry(base, "/features", "0.8", "weekly"),
      entry(base, "/apps", "0.7", "weekly"),
      entry(base, "/countries", "0.7", "weekly"),
      entry(base, "/alternatives/builtwith", "0.8", "weekly"),
      entry(base, "/alternatives/wappalyzer", "0.8", "weekly"),
      entry(base, "/alternatives/storeleads", "0.8", "weekly"),
      entry(base, "/alternatives/zoominfo", "0.8", "weekly"),
      entry(base, "/alternatives/myip-ms", "0.8", "weekly"),
      entry(base, "/hiring", "0.8", "daily"),
      entry(base, "/tools/shopify-checker", "0.8", "weekly"),
      entry(base, "/tools/tech-lookup", "0.8", "weekly"),
      entry(base, "/new-stores", "0.7", "daily"),
      # Scoring methodology — high priority: these are the pages that explain
      # what the product actually measures, and the ones LLMs quote.
      entry(base, "/scoring/seo-score", "0.8", "monthly"),
      entry(base, "/scoring/reputation", "0.8", "monthly"),
      entry(base, "/scoring/revenue-estimation", "0.8", "monthly"),
      entry(base, "/scoring/shopify-store-score", "0.8", "monthly"),
    ]

    all = marketing ++ compares ++ stores ++ techs ++ countries
    xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n" <> Enum.join(all, "\n") <> "\n</urlset>"

    conn
    |> put_resp_content_type("application/xml")
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600")
    |> send_resp(200, xml)
  end

  defp entry(base, path, priority, freq) do
    "  <url><loc>" <> base <> path <> "</loc><changefreq>" <> freq <> "</changefreq><priority>" <> priority <> "</priority></url>"
  end
end
