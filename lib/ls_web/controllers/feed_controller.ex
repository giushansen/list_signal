defmodule LSWeb.FeedController do
  @moduledoc "RSS/Atom feeds of newly discovered stores."
  use LSWeb, :controller
  plug :cache_headers

  def new_stores(conn, _params) do
    # 30s, not hours: on these two pages freshness IS the product. Long enough
    # that a traffic spike costs one query rather than thousands, short enough
    # that "detected today" stays true.
    stores =
      LS.UICache.fetch(:feed, :shopify, fn ->
        case LS.Clickhouse.recent_stores(50) do
          {:ok, rows} -> Enum.map(rows, &feed_row/1)
          _ -> []
        end
      end)

    conn
    |> assign(:page_title, "Latest Shopify Stores — Detected Today")
    |> assign(:feed_h1, "Latest Shopify Stores — Detected Today")
    |> assign(:page_description, "Live feed of newly detected Shopify stores. Updated continuously via SSL Certificate Transparency monitoring.")
    |> assign(:stores, stores)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:new_stores)
  end

  @doc false
  def new_stores_legacy(conn, _params) do
    conn |> put_status(301) |> redirect(to: "/latest-shopify-stores") |> halt()
  end

  # /saas — public feed of the newest classified SaaS & digital businesses.
  def saas(conn, _params) do
    stores =
      LS.UICache.fetch(:feed, :saas, fn ->
        case LS.Clickhouse.recent_by_model(["SaaS", "Tool", "Marketplace"], 50) do
          {:ok, rows} -> Enum.map(rows, &feed_row/1)
          _ -> []
        end
      end)

    conn
    |> assign(:page_title, "Latest SaaS & Digital Businesses")
    |> assign(:page_description, "Live feed of newly classified SaaS and digital businesses, checked continuously by ListSignal.")
    |> assign(:feed_h1, "Latest SaaS & Digital Businesses")
    |> assign(:stores, stores)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:new_stores)
  end

  defp feed_row(row) do
    %{
      domain: Enum.at(row, 0) || "",
      country: Enum.at(row, 1) || "",
      title: Enum.at(row, 2) || "",
      tech: Enum.at(row, 3) || "",
      enriched_at: Enum.at(row, 4)
    }
  end

  @doc false
  def saas_legacy(conn, _params) do
    conn |> put_status(301) |> redirect(to: "/latest-saas-businesses") |> halt()
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=60, max-age=30")
    |> put_resp_header("vary", "Accept-Encoding")
  end
end
