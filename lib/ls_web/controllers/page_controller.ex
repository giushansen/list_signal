defmodule LSWeb.PageController do
  @moduledoc "Landing page and other static marketing pages."
  use LSWeb, :controller
  plug :cache_headers

  def home(conn, _params) do
    data = LS.LandingCache.get()

    conn
    |> assign(:page_title, "Live Business Intelligence for Every Online Business")
    |> assign(:page_description, "Live tech stacks, revenue estimates, hiring signals and contact data for Shopify stores, SaaS products, agencies, and every digital business. No credits, no stale data.")
    |> assign(:landing, data)
    |> assign(:json_ld, home_json_ld())
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:home)
  end

  def pricing(conn, _params) do
    conn
    |> assign(:page_title, "Pricing, Plans from $0 to $149/mo")
    |> assign(:page_description, "Flat plans from free to $149/mo plus a $499 custom prospect list. API included on every plan. No credits, no expiring tokens.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:pricing)
  end

  def features(conn, _params) do
    conn
    |> assign(:page_title, "Features, What ListSignal Tracks")
    |> assign(:page_description, "Technology detection, Shopify app tracking, business classification, revenue estimation, hiring signals, and CSV export for millions of online businesses, checked live.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:features)
  end

  def developers(conn, _params) do
    conn
    |> assign(:page_title, "Developer API and MCP Server")
    |> assign(:page_description, "Query 14M+ online businesses by tech stack, revenue, and hiring signals. REST API + MCP server for AI agents. Free tier: 1,000 lookups/month, no card required.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:developers)
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
      "description" => "Live business intelligence for every online business. Technology detection, revenue estimates, hiring signals, and lead data, checked in real time.",
      "applicationCategory" => "BusinessApplication", "operatingSystem" => "Web",
      "offers" => [
        %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD", "name" => "Free"},
        %{"@type" => "Offer", "price" => "39", "priceCurrency" => "USD", "name" => "Starter"},
        %{"@type" => "Offer", "price" => "99", "priceCurrency" => "USD", "name" => "Pro"}
      ]
    })
  end
end
