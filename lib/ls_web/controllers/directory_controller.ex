defmodule LSWeb.DirectoryController do
  @moduledoc """
  Hub/directory pages that serve as internal link magnets.
  /apps → links to every /tech/:slug page
  /countries → links to every /top/shopify-stores-:code page
  """
  use LSWeb, :controller

  plug :cache_headers

  def apps(conn, _params) do
    techs = case LS.Clickhouse.tech_directory() do
      {:ok, rows} -> Enum.map(rows, fn [name, count] -> %{name: name, count: count} end)
      _ -> []
    end

    conn
    |> assign(:page_title, "Shopify App Directory — All Tracked Technologies")
    |> assign(:page_description, "Browse #{length(techs)} technologies and apps detected across Shopify stores. See adoption data for each.")
    |> assign(:techs, techs)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:apps)
  end

  def countries(conn, _params) do
    countries = case LS.Clickhouse.country_directory() do
      {:ok, rows} -> Enum.map(rows, fn [code, count] -> %{code: code, count: count} end)
      _ -> []
    end

    conn
    |> assign(:page_title, "Shopify Stores by Country")
    |> assign(:page_description, "Browse Shopify stores across #{length(countries)} countries. See top stores in each market.")
    |> assign(:countries, countries)
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:countries)
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end
end
