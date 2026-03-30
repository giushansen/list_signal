defmodule LSWeb.SitemapController do
  use LSWeb, :controller

  def index(conn, _params) do
    base = "https://listsignal.com"

    stores = case LS.Clickhouse.all_shopify_domains(10_000) do
      {:ok, rows} -> Enum.map(rows, fn [d] -> entry(base, "/shopify/" <> String.replace(d, ".", "-"), "0.6", "weekly") end)
      _ -> []
    end

    techs = case LS.Clickhouse.all_tech_slugs() do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
          [
            entry(base, "/tech/" <> slug, "0.7", "weekly"),
            entry(base, "/top/shopify-stores-using-" <> slug, "0.6", "weekly"),
          ]
        end)
      _ -> []
    end

    countries = case LS.Clickhouse.country_directory() do
      {:ok, rows} -> Enum.map(rows, fn [code, _] -> entry(base, "/top/shopify-stores-" <> String.downcase(code), "0.6", "weekly") end)
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
      entry(base, "/tools/shopify-checker", "0.8", "weekly"),
      entry(base, "/tools/tech-lookup", "0.8", "weekly"),
      entry(base, "/new-stores", "0.7", "daily"),
    ]

    all = marketing ++ stores ++ techs ++ countries
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
