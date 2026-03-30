defmodule LSWeb.ToolsController do
  @moduledoc """
  Free SEO tool pages.
  /tools/shopify-checker — is this site on Shopify?
  /tools/tech-lookup — what tech does this domain use?
  /api/tools/lookup — JSON endpoint for JS-powered lookups
  """
  use LSWeb, :controller

  def shopify_checker(conn, _params) do
    conn
    |> assign(:page_title, "Free Shopify Store Checker — Is This Site on Shopify?")
    |> assign(:page_description, "Enter any URL to instantly check if it runs on Shopify. See detected apps, theme, and tech stack. Free, no signup required.")
    |> assign(:json_ld, tool_json_ld("Shopify Store Checker", "Check if any website runs on Shopify"))
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:shopify_checker)
  end

  def tech_lookup(conn, _params) do
    conn
    |> assign(:page_title, "Free Tech Stack Lookup — What Technologies Does This Site Use?")
    |> assign(:page_description, "Enter any URL to see its full technology stack. Detects 200+ technologies from DNS, HTTP, and network signals. Free, no signup.")
    |> assign(:json_ld, tool_json_ld("Tech Stack Lookup", "Detect technologies used by any website"))
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:tech_lookup)
  end

  @doc "JSON API endpoint for JS-powered lookups (landing page search + tool pages)"
  def api_lookup(conn, %{"domain" => domain}) when is_binary(domain) and domain != "" do
    require Logger
    Logger.info("[API] Lookup request for: #{domain}")
    case LS.Tools.Lookup.lookup(domain) do
      {:ok, data} ->
        Logger.info("[API] Lookup OK for #{domain} — shopify:#{data[:is_shopify]} techs:#{length(data.tech)}")
        json(conn, %{ok: true, data: data})
      {:error, reason} ->
        Logger.warning("[API] Lookup FAILED for #{domain}: #{inspect(reason)}")
        conn |> put_status(422) |> json(%{ok: false, error: to_string(reason)})
    end
  end

  def api_lookup(conn, _params) do
    conn |> put_status(400) |> json(%{ok: false, error: "Missing domain parameter"})
  end

  defp tool_json_ld(name, desc) do
    Jason.encode!(%{
      "@context" => "https://schema.org", "@type" => "WebApplication",
      "name" => name, "description" => desc,
      "applicationCategory" => "UtilitiesApplication", "operatingSystem" => "Web",
      "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"}
    })
  end
end
