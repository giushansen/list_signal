defmodule LSWeb.PageController do
  use LSWeb, :controller
  plug :cache_headers

  def home(conn, _params) do
    data = LS.LandingCache.get()

    conn
    |> assign(:page_title, "Shopify Store Intelligence, Instantly")
    |> assign(:page_description, "Discover any Shopify store's tech stack, installed apps, revenue signals and contact data. Updated daily.")
    |> assign(:landing, data)
    |> assign(:json_ld, home_json_ld())
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:home)
  end

  def pricing(conn, _params) do
    conn
    |> assign(:page_title, "Pricing")
    |> assign(:page_description, "Simple pricing, no credits, no surprises. Start free, upgrade when you need more.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:pricing)
  end

  def features(conn, _params) do
    conn
    |> assign(:page_title, "Features")
    |> assign(:page_description, "Domain lookup, technology search, real-time alerts, unlimited CSV exports, and REST API.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:features)
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end

  defp home_json_ld do
    Jason.encode!(%{
      "@context" => "https://schema.org", "@type" => "WebApplication",
      "name" => "ListSignal", "url" => "https://listsignal.com",
      "description" => "Shopify store intelligence platform.",
      "applicationCategory" => "BusinessApplication", "operatingSystem" => "Web",
      "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"}
    })
  end
end
