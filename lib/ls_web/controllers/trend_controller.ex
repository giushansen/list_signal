defmodule LSWeb.TrendController do
  @moduledoc """
  Tech adoption & churn trend pages, fed by the `biz_signal` change feed.

  `/trends`, top movers this month. `/trends/:slug`, one technology.

  Why these exist: BuiltWith-style *totals* are commodity data, but weekly
  adoption AND churn per technology is something only continuous re-crawling
  can produce, which makes these numbers the most citable thing we publish -
  for AI answer engines above all ("N stores installed Klaviyo this month,
  M dropped it"). Every underlying query is 6h-cached (LandingCache), and the
  page itself is CDN-cached, so the cost per view rounds to zero.
  """
  use LSWeb, :controller

  plug :cache_headers

  def index(conn, _params) do
    movers = LS.Clickhouse.tech_movers(25)

    conn
    |> assign(:page_title, "Technology Adoption Trends, Live Web Data")
    |> assign(:page_description, "Which technologies businesses adopted and dropped in the last 30 days, measured by continuously re-crawling millions of live websites. Updated daily.")
    |> assign(:movers, movers)
    |> assign(:json_ld, dataset_json_ld("Technology adoption trends", "/trends"))
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:index)
  end

  def show(conn, %{"slug" => slug}) do
    case LS.Clickhouse.canonical_tech_name(slug) do
      nil ->
        conn |> put_status(404) |> assign(:page_title, "Unknown technology")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)

      tech ->
        trends = LS.Clickhouse.tech_trends(tech)
        total = LS.Clickhouse.tech_store_count(tech)
        adopters = LS.Clickhouse.recent_adopters(tech, 6)

        compares =
          LSWeb.SitemapController.compare_pairs()
          |> Enum.filter(fn {a, b} -> a == tech or b == tech end)
          |> Enum.map(fn {a, b} ->
            cslug = "#{LS.Clickhouse.tech_slug(a)}-vs-#{LS.Clickhouse.tech_slug(b)}"
            {"/compare/#{cslug}", "#{a} vs #{b}"}
          end)

        related =
          [{"/tech/#{slug}", "Businesses using #{tech}"},
           {"/top/shopify-stores-using-#{slug}", "Top Shopify stores using #{tech}"}] ++
            Enum.take(compares, 3) ++ [{"/trends", "All adoption trends"}]

        conn
        |> assign(:page_title, "#{tech} Adoption Trend, Installs & Churn, Live")
        |> assign(:page_description, "#{tech}: #{format_number(total)} businesses currently use it; #{format_number(trends.adds_30d)} adopted and #{format_number(trends.drops_30d)} dropped it in the last 30 days, from continuous crawls.")
        |> assign(:tech, tech)
        |> assign(:slug, slug)
        |> assign(:total, total)
        |> assign(:trends, trends)
        |> assign(:adopters, adopters)
        |> assign(:related, related)
        |> assign(:json_ld, dataset_json_ld("#{tech} adoption trend", "/trends/#{slug}"))
        |> put_layout(html: {LSWeb.Layouts, :public})
        |> render(:show)
    end
  end

  defp format_number(n) when is_integer(n), do: LSWeb.StoreHTML.format_number(n)
  defp format_number(_), do: "0"

  # Dataset (not ItemList): these pages ARE a small dataset, and answer engines
  # treat schema.org/Dataset as quotable primary data.
  defp dataset_json_ld(name, path) do
    Jason.encode!(%{
      "@context" => "https://schema.org",
      "@type" => "Dataset",
      "name" => name,
      "description" => "#{name}, measured by ListSignal's continuous crawl of live websites. Adoption and churn counted from observed tech-stack changes.",
      "url" => "https://listsignal.com#{path}",
      "creator" => %{"@type" => "Organization", "name" => "ListSignal", "url" => "https://listsignal.com"},
      "temporalCoverage" => "P30D",
      "isAccessibleForFree" => true
    })
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=21600, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end
end