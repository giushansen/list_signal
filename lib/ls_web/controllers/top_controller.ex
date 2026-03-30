defmodule LSWeb.TopController do
  @moduledoc """
  Top/ranking programmatic SEO pages.

  URL patterns:
    /top/shopify-stores-us           → top stores in US
    /top/shopify-stores-using-klaviyo → top stores using Klaviyo
    /top/shopify-stores-using-klaviyo-in-us → combined

  These "best of" list pages are the #1 format cited by AI search engines.
  """
  use LSWeb, :controller

  plug :cache_headers

  @country_names %{
    "US" => "United States", "GB" => "United Kingdom", "CA" => "Canada",
    "AU" => "Australia", "DE" => "Germany", "FR" => "France", "NL" => "Netherlands",
    "SE" => "Sweden", "JP" => "Japan", "KR" => "South Korea", "IN" => "India",
    "BR" => "Brazil", "NZ" => "New Zealand", "IE" => "Ireland", "SG" => "Singapore",
    "IT" => "Italy", "ES" => "Spain", "DK" => "Denmark", "NO" => "Norway",
    "FI" => "Finland", "BE" => "Belgium", "CH" => "Switzerland", "AT" => "Austria",
    "PL" => "Poland", "PT" => "Portugal", "MX" => "Mexico", "IL" => "Israel",
    "HK" => "Hong Kong", "TW" => "Taiwan", "AE" => "UAE", "ZA" => "South Africa"
  }

  def show(conn, %{"slug" => slug}) do
    case parse_top_slug(slug) do
      {:country, code} ->
        render_country_top(conn, code, slug)

      {:tech, tech_name} ->
        render_tech_top(conn, tech_name, slug)

      {:tech_country, tech_name, code} ->
        render_tech_country_top(conn, tech_name, code, slug)

      :error ->
        conn |> put_status(404) |> assign(:page_title, "Page Not Found")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)
    end
  end

  defp render_country_top(conn, code, slug) do
    country_name = Map.get(@country_names, String.upcase(code), String.upcase(code))
    case LS.Clickhouse.top_stores_by_country(String.upcase(code), 50) do
      {:ok, rows} when rows != [] ->
        stores = parse_rows(rows)
        conn
        |> assign(:page_title, "Top #{length(stores)} Shopify Stores in #{country_name}")
        |> assign(:page_description, "The highest-ranked Shopify stores in #{country_name}, sorted by traffic. Updated daily by ListSignal.")
        |> assign(:heading, "Top Shopify Stores in #{country_name}")
        |> assign(:subtext, "#{length(stores)} stores ranked by traffic estimate. Updated daily.")
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top Shopify Stores in #{country_name}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)
      _ ->
        conn |> put_status(404) |> assign(:page_title, "Page Not Found")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)
    end
  end

  defp render_tech_top(conn, tech_name, slug) do
    case LS.Clickhouse.top_stores_using_tech(tech_name, 50) do
      {:ok, rows} when rows != [] ->
        stores = parse_rows(rows)
        conn
        |> assign(:page_title, "Top Shopify Stores Using #{tech_name}")
        |> assign(:page_description, "#{length(stores)} Shopify stores using #{tech_name}, ranked by traffic. Updated daily.")
        |> assign(:heading, "Top Shopify Stores Using #{tech_name}")
        |> assign(:subtext, "#{length(stores)} stores ranked by traffic estimate. Updated daily.")
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top Shopify Stores Using #{tech_name}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)
      _ ->
        conn |> put_status(404) |> assign(:page_title, "Page Not Found")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)
    end
  end

  defp render_tech_country_top(conn, tech_name, code, slug) do
    country_name = Map.get(@country_names, String.upcase(code), String.upcase(code))
    case LS.Clickhouse.top_stores_using_tech_in_country(tech_name, String.upcase(code), 50) do
      {:ok, rows} when rows != [] ->
        stores = parse_rows(rows)
        conn
        |> assign(:page_title, "Top Shopify Stores Using #{tech_name} in #{country_name}")
        |> assign(:page_description, "#{length(stores)} Shopify stores using #{tech_name} in #{country_name}.")
        |> assign(:heading, "Top Shopify Stores Using #{tech_name} in #{country_name}")
        |> assign(:subtext, "#{length(stores)} stores. Updated daily.")
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top Shopify Stores Using #{tech_name} in #{country_name}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)
      _ ->
        conn |> put_status(404) |> assign(:page_title, "Page Not Found")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)
    end
  end

  # Parse URL slug patterns
  # "shopify-stores-us" -> {:country, "US"}
  # "shopify-stores-using-klaviyo" -> {:tech, "Klaviyo"}
  # "shopify-stores-using-klaviyo-in-us" -> {:tech_country, "Klaviyo", "US"}
  defp parse_top_slug(slug) do
    cond do
      slug =~ ~r/^shopify-stores-using-(.+)-in-([a-z]{2})$/ ->
        [_, tech, country] = Regex.run(~r/^shopify-stores-using-(.+)-in-([a-z]{2})$/, slug)
        {:tech_country, humanize(tech), String.upcase(country)}

      slug =~ ~r/^shopify-stores-using-(.+)$/ ->
        [_, tech] = Regex.run(~r/^shopify-stores-using-(.+)$/, slug)
        {:tech, humanize(tech)}

      slug =~ ~r/^shopify-stores-([a-z]{2})$/ ->
        [_, country] = Regex.run(~r/^shopify-stores-([a-z]{2})$/, slug)
        {:country, String.upcase(country)}

      true -> :error
    end
  end

  defp humanize(slug), do: slug |> String.split("-") |> Enum.map(&String.capitalize/1) |> Enum.join(" ")

  defp parse_rows(rows) do
    Enum.map(rows, fn row ->
      %{domain: Enum.at(row, 0) || "", title: Enum.at(row, 1) || "",
        tech: Enum.at(row, 2) || "", country: Enum.at(row, 3) || "",
        rank: Enum.at(row, 4)}
    end)
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end

  defp list_json_ld(name, count) do
    Jason.encode!(%{
      "@context" => "https://schema.org", "@type" => "ItemList",
      "name" => name, "numberOfItems" => count,
      "description" => "#{name}. Updated daily by ListSignal."
    })
  end
end
