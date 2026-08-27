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

  # /top/<slug> segment pages. These slugs were linked from the footer for
  # months while parse_top_slug/1 had no branch for them — live 404s advertised
  # sitewide. Names must match the classifier's business_model / industry
  # vocabularies exactly.
  @model_slugs %{
    "ecommerce" => "Ecommerce", "saas" => "SaaS", "agency" => "Agency",
    "marketplace" => "Marketplace", "tool" => "Tool", "directory" => "Directory",
    "newsletter" => "Newsletter", "manufacturer" => "Manufacturer"
  }

  @industry_slugs %{
    "fashion" => "Fashion", "beauty" => "Beauty", "healthcare" => "Healthcare",
    "education" => "Education", "fintech" => "Fintech", "travel" => "Travel",
    "legal" => "Legal", "security" => "Security", "logistics" => "Logistics",
    "marketing" => "Marketing", "devtools" => "DevTools",
    "productivity" => "Productivity", "ai" => "AI & ML",
    "real-estate" => "Real Estate", "food-beverage" => "Food & Beverage",
    "home-garden" => "Home & Garden", "media" => "Media & Entertainment",
    "hr" => "HR & Recruiting", "construction" => "Construction & Manufacturing"
  }

  @doc "slug => display name, both kinds, the sitemap emits from these."
  def segment_slugs, do: %{model: @model_slugs, industry: @industry_slugs}

  def show(conn, %{"slug" => slug}) do
    case parse_top_slug(slug) do
      {:country, code} ->
        render_country_top(conn, code, slug)

      {:tech, tech_name} ->
        render_tech_top(conn, tech_name, slug)

      {:tech_country, tech_name, code} ->
        render_tech_country_top(conn, tech_name, code, slug)

      {:segment, kind, name} ->
        render_segment_top(conn, kind, name, slug)

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
        |> assign(:page_description, "The highest-ranked Shopify stores in #{country_name}, sorted by traffic. Checked continuously by ListSignal.")
        |> assign(:heading, "Top Shopify Stores in #{country_name}")
        |> assign(:subtext, "#{length(stores)} stores ranked by traffic estimate. Domains checked in real time; tech re-scanned weekly.")
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top Shopify Stores in #{country_name}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)
      {:ok, _empty} ->
        not_found(conn)

      {:error, reason} ->
        unavailable(conn, slug, reason)
    end
  end

  defp render_tech_top(conn, tech_name, slug) do
    case LS.Clickhouse.top_stores_using_tech(tech_name, 50) do
      {:ok, rows} when rows != [] ->
        stores = parse_rows(rows)
        conn
        |> assign(:page_title, "Top Shopify Stores Using #{tech_name}")
        |> assign(:page_description, "#{length(stores)} Shopify stores using #{tech_name}, ranked by traffic. Checked continuously.")
        |> assign(:heading, "Top Shopify Stores Using #{tech_name}")
        |> assign(:subtext, "#{length(stores)} stores ranked by traffic estimate. Domains checked in real time; tech re-scanned weekly.")
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top Shopify Stores Using #{tech_name}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)
      {:ok, _empty} ->
        not_found(conn)

      {:error, reason} ->
        unavailable(conn, slug, reason)
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
        |> assign(:subtext, "#{length(stores)} stores. Checked continuously.")
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top Shopify Stores Using #{tech_name} in #{country_name}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)
      {:ok, _empty} ->
        not_found(conn)

      {:error, reason} ->
        unavailable(conn, slug, reason)
    end
  end

  defp render_segment_top(conn, kind, name, slug) do
    case LS.Clickhouse.top_by_segment(kind, name, 50) do
      {:ok, rows} when rows != [] ->
        stores = parse_rows(rows)
        total = segment_total(kind, name)
        noun = if kind == :tech, do: "#{name} Stores", else: "#{name} Businesses"
        total_str = if total, do: LSWeb.StoreHTML.format_number(total), else: "#{length(stores)}+"

        conn
        |> assign(:page_title, "Top #{noun}, Ranked by Traffic")
        |> assign(:page_description, "The #{length(stores)} highest-ranked #{name} businesses out of #{total_str} tracked, from live crawls of the whole web. Checked continuously by ListSignal.")
        |> assign(:heading, "Top #{noun}")
        |> assign(:subtext, "Out of #{total_str} #{name} businesses ListSignal tracks, ranked by traffic estimate, checked continuously.")
        |> assign(:cta_text, "Get all #{total_str} #{name} businesses as a list, emails included")
        |> assign(:related, segment_related(kind, slug))
        |> assign(:stores, stores) |> assign(:slug, slug)
        |> assign(:json_ld, list_json_ld("Top #{noun}", length(stores)))
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:show)

      {:ok, _empty} ->
        not_found(conn)

      {:error, reason} ->
        unavailable(conn, slug, reason)
    end
  end

  defp segment_total(:tech, _name), do: LS.Clickhouse.shopify_store_count()
  defp segment_total(kind, name), do: LS.Clickhouse.segment_counts(kind)[name]

  # 4-5 sibling links, deterministic rotation per slug so the mesh varies page
  # to page instead of every page linking the same four siblings.
  defp segment_related(kind, slug) do
    %{model: models, industry: industries} = segment_slugs()
    pool = if kind == :industry, do: industries, else: models

    siblings =
      pool
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reject(&(&1 == slug))
      |> then(fn keys ->
        offset = rem(:erlang.phash2(slug), max(length(keys), 1))
        Enum.slice(keys ++ keys, offset, 3)
      end)
      |> Enum.map(fn s -> {"/top/#{s}", "Top #{pool[s]}"} end)

    siblings ++ [{"/trends", "Tech adoption trends"}, {"/countries", "Stores by country"}]
  end

  defp not_found(conn) do
    conn |> put_status(404) |> assign(:page_title, "Page Not Found")
    |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)
  end

  # A ClickHouse failure is NOT "this page does not exist". These pages used to
  # collapse both into 404, so when country_expr/0 blew the query timeout Google
  # was told every /top/* URL was permanently gone — while the sitemap kept
  # advertising them. 503 + Retry-After keeps the URL in the index and asks Google
  # to come back, which is the honest answer when the data store is the problem.
  defp unavailable(conn, slug, reason) do
    require Logger
    Logger.error("[TOP] /top/#{slug} unavailable: #{inspect(reason)}")

    conn
    |> put_status(503)
    |> put_resp_header("retry-after", "3600")
    |> assign(:page_title, "Temporarily Unavailable")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:not_found)
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

      slug == "shopify" ->
        {:segment, :tech, "Shopify"}

      Map.has_key?(@model_slugs, slug) ->
        {:segment, :model, @model_slugs[slug]}

      Map.has_key?(@industry_slugs, slug) ->
        {:segment, :industry, @industry_slugs[slug]}

      true -> :error
    end
  end

  # Same trap as the other controllers: "vue-js" must resolve to "Vue.js", not
  # "Vue Js", or the ClickHouse LIKE matches nothing and the page 404s.
  defp humanize(slug) do
    LS.Clickhouse.canonical_tech_name(slug) ||
      (slug |> String.split("-") |> Enum.map(&String.capitalize/1) |> Enum.join(" "))
  end

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
      "description" => "#{name}. Checked continuously by ListSignal."
    })
  end
end
