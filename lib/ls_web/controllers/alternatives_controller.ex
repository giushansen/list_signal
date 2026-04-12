defmodule LSWeb.AlternativesController do
  @moduledoc """
  Competitor alternative pages.
  /alternatives/builtwith, /alternatives/wappalyzer, etc.
  Captures high-intent "X alternative" searches.
  """
  use LSWeb, :controller
  plug :cache_headers

  @competitors %{
    "builtwith" => %{
      name: "BuiltWith",
      tagline: "Same depth. 1/4 the price. Fresher data.",
      price: "$295–$995/mo",
      ls_price: "Free – $99/mo",
      pros: [
        "113,000+ technologies tracked (largest database)",
        "18 years of historical data",
        "Revenue estimates included"
      ],
      cons: [
        "Data refreshes weekly to quarterly — often stale",
        "Exports are messy and hard to import into CRMs",
        "UI requires training to navigate",
        "Minimum $295/mo locks out small teams",
        "Opaque methodology — no timestamps on data"
      ],
      ls_wins: [
        {"⚡", "Real-time detection", "We detect new stores within hours via SSL Certificate Transparency logs. BuiltWith relies on periodic web crawls."},
        {"🔍", "Transparent timestamps", "Every data point shows exactly when it was collected. No guessing if data is fresh."},
        {"💰", "85% cheaper", "Plans from $39/mo vs BuiltWith's $295 minimum. Same store and tech data."},
        {"📤", "Clean exports", "CSV exports designed for CRM import. No cleaning needed."},
        {"🏗️", "Hosting, email provider, and network data", "Hosting provider, email service, server location, and domain age data that BuiltWith doesn't surface."},
        {"🤖", "AI-ready data", "Structured data with API access designed for automation and AI workflows."}
      ]
    },
    "wappalyzer" => %{
      name: "Wappalyzer",
      tagline: "No credits. No expiration. Just data.",
      price: "$250–$850/mo",
      ls_price: "Free – $99/mo",
      pros: [
        "Browser extension with 2M+ daily users",
        "94% React detection accuracy (best in class)",
        "Good at catching client-side technologies"
      ],
      cons: [
        "Credit system with 60-day expiration",
        "Only ~2,500 technology signatures (vs our 200+ and growing)",
        "No historical trend data",
        "Credits consumed even on failed lookups",
        "Minimum $250/mo for meaningful access"
      ],
      ls_wins: [
        {"🚫", "No credits, ever", "Wappalyzer's credits expire after 60 days. ListSignal has zero credit system — flat monthly price."},
        {"⚡", "Server-side detection", "We scan from infrastructure level (DNS, HTTP, BGP), not just browser. Catches backend tech Wappalyzer misses."},
        {"💰", "84% cheaper", "Plans from $39/mo vs Wappalyzer's $250 minimum for useful access."},
        {"📊", "Shopify specialization", "Deep Shopify data: app detection, theme, plan tier, revenue signals."},
        {"🏗️", "Hosting, email provider, and network data", "Hosting provider, email service, server location, and domain age data — data Wappalyzer doesn't have."},
        {"🕐", "Data freshness timestamps", "Know exactly when each domain was last scanned. Wappalyzer doesn't show this."}
      ]
    },
    "storeleads" => %{
      name: "StoreLeads",
      tagline: "Shopify-first intelligence. Fraction of the cost.",
      price: "$75–$950/mo",
      ls_price: "Free – $99/mo",
      pros: [
        "2.8M Shopify stores with deep ecommerce data",
        "6,502 Shopify apps tracked with install dates",
        "Revenue estimates and social media data",
        "Covers 403 ecommerce platforms (not just Shopify)"
      ],
      cons: [
        "CSV export requires $250/mo plan minimum",
        "API access starts at $250/mo",
        "Data refreshes weekly (not daily)",
        "No infrastructure/network data",
        "No hosting provider, email service, or server location data"
      ],
      ls_wins: [
        {"⚡", "Detected within hours, not days", "New stores appear in ListSignal within hours via CT log monitoring. StoreLeads updates weekly."},
        {"💰", "CSV exports from $39/mo", "StoreLeads charges $250/mo for CSV export. ListSignal includes CSV exports starting at $39/mo."},
        {"🏗️", "Infrastructure insights competitors don't have", "Hosting provider, email service, server location, and domain age data — data StoreLeads doesn't collect."},
        {"🔬", "Transparent methodology", "We show exactly when and how each data point was collected. Full audit trail."},
        {"🤝", "Startup-level support", "Direct access to founders. Not a ticket queue."},
        {"🤖", "AI classification", "Automated industry classification and business summary powered by ML."}
      ],
      honest_note: "StoreLeads covers 403 ecommerce platforms. ListSignal currently specializes in Shopify with deep infrastructure data, plus broad SaaS coverage. If you need Magento, WooCommerce, or BigCommerce data today, StoreLeads is more complete. If you need the freshest Shopify data with infrastructure intelligence, ListSignal wins."
    },
    "zoominfo" => %{
      name: "ZoomInfo",
      tagline: "Domain intelligence without the enterprise price tag.",
      price: "$15,000–$60,000/yr",
      ls_price: "Free – $99/mo",
      pros: [
        "Massive B2B contact database (100M+ profiles)",
        "Intent data and buyer signals",
        "Deep CRM integrations (Salesforce, HubSpot)",
        "Established enterprise sales tool"
      ],
      cons: [
        "Minimum $15K/year contracts",
        "Credit system with aggressive upselling",
        "10-20% annual price increases reported",
        "Technology data is not the primary focus",
        "Lock-in contracts with difficult cancellation"
      ],
      ls_wins: [
        {"💰", "97% cheaper for tech data", "ZoomInfo's minimum is $15K/yr. ListSignal starts at $39/mo for full tech lookups."},
        {"🎯", "Purpose-built for tech intelligence", "ZoomInfo is a contact database that happens to have tech data. ListSignal is built specifically for technology detection."},
        {"📅", "Month-to-month, cancel anytime", "No annual contracts. No lock-in. No 10-20% surprise renewals."},
        {"⚡", "Real-time detection", "New domains detected within hours via CT logs. ZoomInfo's tech data lags by weeks."},
        {"🏗️", "Infrastructure insights competitors don't have", "Hosting provider, email service, server location, and domain age data that ZoomInfo doesn't surface at all."},
        {"🔓", "No sales call required", "Sign up and start using immediately. ZoomInfo requires a sales demo."}
      ]
    }
  }

  def show(conn, %{"competitor" => slug}) do
    case Map.get(@competitors, slug) do
      nil ->
        conn |> put_status(404) |> assign(:page_title, "Not Found")
        |> put_layout(html: {LSWeb.Layouts, :public}) |> render(:not_found)

      comp ->
        store_count = LS.LandingCache.get().store_count

        conn
        |> assign(:page_title, "#{comp.name} Alternative — ListSignal vs #{comp.name}")
        |> assign(:page_description, "Compare ListSignal vs #{comp.name}. #{comp.tagline}")
        |> assign(:comp, comp)
        |> assign(:slug, slug)
        |> assign(:store_count, store_count)
        |> assign(:json_ld, alt_json_ld(comp))
        |> put_layout(html: {LSWeb.Layouts, :public})
        |> render(:show)
    end
  end

  defp cache_headers(conn, _opts) do
    conn
    |> put_resp_header("cache-control", "public, s-maxage=86400, max-age=3600, stale-while-revalidate=3600")
    |> put_resp_header("vary", "Accept-Encoding")
  end

  defp alt_json_ld(comp) do
    Jason.encode!(%{
      "@context" => "https://schema.org", "@type" => "WebPage",
      "name" => "ListSignal vs #{comp.name}",
      "description" => "Compare ListSignal and #{comp.name} for Shopify store intelligence."
    })
  end
end
