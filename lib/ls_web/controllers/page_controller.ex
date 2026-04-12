defmodule LSWeb.PageController do
  use LSWeb, :controller
  plug :cache_headers

  def home(conn, _params) do
    data = LS.LandingCache.get()

    conn
    |> assign(:page_title, "Domain Intelligence, Updated Daily")
    |> assign(:page_description, "Fresh tech stack, app detection, revenue signals and contact data for Shopify stores, SaaS products, and every digital business. No credits, no stale data.")
    |> assign(:landing, data)
    |> assign(:json_ld, home_json_ld())
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:home)
  end

  def pricing(conn, _params) do
    conn
    |> assign(:page_title, "Pricing — Plans from $0 to $99/mo")
    |> assign(:page_description, "Three flat-rate plans. No credits, no expiring tokens. Start free, export from $39/mo. Save 20%+ with annual billing.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:pricing)
  end

  def features(conn, _params) do
    conn
    |> assign(:page_title, "Features — What ListSignal Tracks")
    |> assign(:page_description, "Technology detection, Shopify app tracking, business classification, revenue estimation, and CSV export for millions of domains — updated daily.")
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
      "description" => "Domain intelligence for digital businesses. Technology detection, Shopify app tracking, and lead data — updated daily.",
      "applicationCategory" => "BusinessApplication", "operatingSystem" => "Web",
      "offers" => [
        %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD", "name" => "Free"},
        %{"@type" => "Offer", "price" => "39", "priceCurrency" => "USD", "name" => "Starter"},
        %{"@type" => "Offer", "price" => "99", "priceCurrency" => "USD", "name" => "Pro"}
      ]
    })
  end
end
