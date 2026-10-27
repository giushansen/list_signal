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
    |> assign(:page_title, "Pricing, Plans from $0 to $#{LS.Plans.monthly("scale")}/mo")
    |> assign(:page_description, "Flat plans from free to $#{LS.Plans.monthly("scale")}/mo, one allowance of rows spent as CSV, API or MCP, plus lists built for you at $#{LS.Plans.monthly("dfy")}/mo. No credits, no expiring tokens.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:pricing)
  end

  # The buyer-facing data page (2026-10-27): every customer-facing column
  # with a value on two fictional businesses, the shared filter grammar,
  # the signals, and three questions asked in English with the dashboard,
  # API and MCP forms of each. Generated from the same declarations the
  # product runs on (LS.Schema.Columns, LS.Query, LS.Schema.Examples) so
  # it cannot drift from the dashboard, the CSV or the API.
  def data(conn, _params) do
    conn
    |> assign(:page_title, "The Data: Every Field on Every Business")
    |> assign(:page_description, "121 fields on every online business, 26 of them watched for change, shown on a fictional Shopify store and a fictional SaaS. Same names in the dashboard, the CSV, the API and the MCP server.")
    |> assign(:json_ld, data_json_ld())
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:data)
  end

  # The URL every ListSignalBot request advertises in its User-Agent. A
  # crawler that names itself must answer for itself: this page is what a
  # site owner (or an abuse desk) finds before deciding to block or report
  # us, so it stays plain, honest and short (2026-09-04, Vultr report #2).
  # The fleet's public crawl addresses, published so an abuse desk or a site
  # owner can tell our traffic from someone spoofing the User-Agent
  # (security audit 2026-09-09, after three Vultr reports). The home node is
  # deliberately absent: a residential address is not ours to publish. Keep
  # in step with devops/listsignal/fleet.conf; LSWeb.BotPageTest checks the
  # shape, and the reverse DNS names live in devops/listsignal/rdns.md.
  # The fleet's public addresses, as fleet.conf lists them (2026-10-27:
  # the seven nodes destroyed on 10-22 removed, chi2/dal2/par2 added).
  @crawler_ips ~w(
    108.61.94.33 207.246.126.235 95.179.216.41 64.177.122.55 45.77.42.191
    45.76.59.43 64.177.125.20 104.238.144.112 108.61.123.237
  )

  @doc false
  def crawler_ips, do: @crawler_ips

  def bot(conn, _params) do
    conn
    |> assign(:crawler_ips, @crawler_ips)
    |> assign(:page_title, "About ListSignalBot")
    |> assign(:page_description, "What the ListSignal crawler does, how often it visits, and how to block it or opt out.")
    |> put_layout(html: {LSWeb.Layouts, :public})
    |> render(:bot)
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
    |> assign(:page_description, "Query 14M+ online businesses by tech stack, revenue, and hiring signals. REST API + MCP server for AI agents, one filter grammar with the dashboard. Free: 1,000 rows a month, counts free, no card required.")
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
      "offers" => plan_offers()
    })
  end

  # The offers every page's structured data lists, from LS.Plans, so the
  # schema.org prices and the pricing page cannot disagree.
  defp plan_offers do
    for plan <- LS.Plans.self_serve() do
      %{"@type" => "Offer", "price" => Integer.to_string(LS.Plans.monthly(plan)), "priceCurrency" => "USD", "name" => LS.Plans.label(plan)}
    end ++
      [%{"@type" => "Offer", "price" => Integer.to_string(LS.Plans.monthly("dfy")), "priceCurrency" => "USD", "name" => "Done for you"}]
  end

  defp data_json_ld do
    Jason.encode!([
      %{
        "@context" => "https://schema.org",
        "@type" => "Dataset",
        "name" => "ListSignal business records",
        "url" => "https://listsignal.com/data",
        "description" => "One record per online business: #{length(LS.Schema.Columns.doc_rows())} fields covering what it is, what it runs, what it sells, what it earns, who to contact and what changed, with #{length(LS.Schema.Columns.tracked())} fields watched for change. Available in the dashboard, as CSV, by REST API and by MCP with one filter grammar.",
        "creator" => %{"@type" => "Organization", "name" => "ListSignal", "url" => "https://listsignal.com"},
        "license" => "https://listsignal.com/terms",
        "isAccessibleForFree" => true,
        "distribution" => [
          %{"@type" => "DataDownload", "encodingFormat" => "text/csv", "contentUrl" => "https://listsignal.com/dashboard"},
          %{"@type" => "DataDownload", "encodingFormat" => "application/json", "contentUrl" => "https://listsignal.com/openapi.json"}
        ],
        "variableMeasured" => Enum.map(LS.Schema.Columns.doc_rows(), fn {name, _, _, _, doc} -> %{"@type" => "PropertyValue", "name" => name, "description" => doc} end)
      },
      %{
        "@context" => "https://schema.org",
        "@type" => "FAQPage",
        "mainEntity" => [
          faq("Are the two example businesses real?", "No. Ridgeline Camp Co and Fieldplan are fictional, the domains do not resolve and the people do not exist. Every value is shaped like a real row read the day the page was written, so the shapes, vocabularies and magnitudes are the ones you get."),
          faq("Is the data the same in the dashboard, the CSV, the API and the MCP server?", "Yes. One record per domain, the same field names on every surface, and one filter grammar: a search built in the dashboard is the same query string on the CSV link and on /api/v1/search, and the same arguments on the MCP tools."),
          faq("What counts as a row?", "A company record. Plans include a monthly allowance of rows spent on any surface: a CSV line, a search result, a company lookup. Counts, group-bys and dataset statistics are free on every plan."),
          faq("How fresh is a record?", "Every business is re-checked on a weekly to monthly cadence and new domains are discovered within hours of their first TLS certificate. Each record carries the timestamps, so you can judge freshness yourself.")
        ]
      }
    ])
  end

  defp faq(q, a), do: %{"@type" => "Question", "name" => q, "acceptedAnswer" => %{"@type" => "Answer", "text" => a}}
end
