defmodule LSWeb.CompareController do
  @moduledoc """
  VS/Comparison programmatic SEO pages.
  URL: /compare/klaviyo-vs-mailchimp

  Captures high-intent "[X] vs [Y]" search queries.
  Each page shows store counts, country distribution,
  overlap, and sample stores for both technologies.
  """
  use LSWeb, :controller

  plug :cache_headers

  def show(conn, %{"slug" => slug}) do
    case parse_vs_slug(slug) do
      {tech_a, tech_b} ->
        data = LS.Clickhouse.compare_techs(tech_a, tech_b)

        conn
        |> assign(:page_title, "#{tech_a} vs #{tech_b} — Shopify App Comparison")
        |> assign(:page_description, "Compare #{tech_a} (#{data.tech_a.count} stores) vs #{tech_b} (#{data.tech_b.count} stores). See which Shopify stores use each app.")
        |> assign(:data, data)
        |> assign(:slug, slug)
        |> assign(:json_ld, compare_json_ld(tech_a, tech_b, data))
        |> put_layout(html: {LSWeb.Layouts, :public})
        |> render(:show)

      :error ->
        conn |> put_status(404) |> assign(:page_title, "Comparison Not Found")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)
    end
  end

  # "klaviyo-vs-mailchimp" -> {"Klaviyo", "Mailchimp"}
  defp parse_vs_slug(slug) do
    case String.split(slug, "-vs-", parts: 2) do
      [a, b] when a != "" and b != "" ->
        {humanize(a), humanize(b)}
      _ -> :error
    end
  end

  defp humanize(slug) do
    slug |> String.split("-") |> Enum.map(&String.capitalize/1) |> Enum.join(" ")
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end

  defp compare_json_ld(a, b, data) do
    Jason.encode!(%{
      "@context" => "https://schema.org",
      "@type" => "WebPage",
      "name" => "#{a} vs #{b} — Shopify App Comparison",
      "description" => "#{a} is used by #{data.tech_a.count} Shopify stores. #{b} is used by #{data.tech_b.count} stores. #{data.both_count} stores use both."
    })
  end
end
