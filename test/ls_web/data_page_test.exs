defmodule LSWeb.DataPageTest do
  @moduledoc """
  The public pages after the 2026-10-27 repricing and the /data page:
  every price on the site comes from LS.Plans, every field on /data from
  LS.Schema.Columns, every filter from LS.Query. These tests catch the
  stale number or the missing field, which is how the site drifted before.
  """
  use LSWeb.ConnCase, async: true

  test "/data lists every field with both examples, the filters, the signals and the three questions", %{conn: conn} do
    html = conn |> get(~p"/data") |> html_response(200)

    for {name, _, _, _, _} <- LS.Schema.Columns.doc_rows(), do: assert(html =~ name, "#{name} missing from /data")
    for f <- LS.Query.filters(), do: assert(html =~ "#{f.name}=#{f.example}", "filter #{f.name} missing from /data")
    for {name, _, _} <- LS.Schema.Columns.tracked(), do: assert(html =~ name)

    assert html =~ "ridgelinecamp.com.au" and html =~ "fieldplan.co.uk"
    assert html =~ "do not exist"
    for q <- LS.Schema.Examples.queries(), do: assert(html =~ Phoenix.HTML.html_escape(q.question) |> Phoenix.HTML.safe_to_string())
    assert html =~ "listsignal_count"
    assert html =~ "/api/v1/count?"
    assert html =~ "Open this search in the dashboard"
    assert html =~ ~s(application/ld+json)
    assert html =~ "Dataset"
  end

  test "the navigation and the sitemap carry /data", %{conn: conn} do
    assert {"/data", "Data"} in LSWeb.Layouts.right_nav_links()
    assert conn |> get(~p"/sitemap.xml") |> response(200) =~ "https://listsignal.com/data"
    assert conn |> get(~p"/") |> html_response(200) =~ ~s(href="/data")
  end

  test "the home page asks a question in English and shows the tool call", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    q = hd(LS.Schema.Examples.queries())
    assert html =~ ~s(id="ask")
    assert html =~ "listsignal_count"
    assert html =~ "ridgelinecamp.com.au"
    assert html =~ LS.Plans.fmt(q.count)
    assert html =~ "1,000 rows a month"
    refute html =~ "1,000 lookups"
  end

  test "the features page shows both example businesses", %{conn: conn} do
    html = conn |> get(~p"/features") |> html_response(200)
    assert html =~ "ridgelinecamp.com.au" and html =~ "fieldplan.co.uk"
    assert html =~ "REST API &amp; MCP Server"
    refute html =~ "Soon"
    refute html =~ ~r/(?<![\d,])5,000 rows/
  end

  test "the pricing page prints the plan table and the done-for-you offer, and no old price", %{conn: conn} do
    html = conn |> get(~p"/pricing") |> html_response(200)

    for plan <- LS.Plans.self_serve() do
      assert html =~ "$#{LS.Plans.monthly(plan)}"
      assert html =~ "#{LS.Plans.fmt(LS.Plans.rows(plan))} rows a month"
    end

    assert html =~ "$#{LS.Plans.fmt(LS.Plans.monthly("dfy"))}"
    assert html =~ ~s(id="done-for-you")
    assert html =~ "within 24 hours"
    for old <- [~r/\$39(?!\d)/, ~r/\$29\//, ~r/\$499/, ~r/(?<![\d,])50,000/, ~r/25,000 calls/, ~r/(?<![\d,])5,000 rows/], do: refute(html =~ old, "stale #{inspect(old)} on /pricing")
  end

  test "the developers page documents count, query, the grammar, six tools and the row plans", %{conn: conn} do
    html = conn |> get(~p"/developers") |> html_response(200)
    assert html =~ "/api/v1/count" and html =~ "/api/v1/query"
    assert html =~ ~s(id="filters")
    for f <- LS.Query.filters(), do: assert(html =~ "#{f.name}=#{f.example}")
    assert html =~ "listsignal_count"
    assert html =~ "six tools"
    assert html =~ "Rows / month"
    for plan <- LS.Plans.self_serve(), do: assert(html =~ LS.Plans.fmt(LS.Plans.rows(plan)))
    refute html =~ "1,000 lookups"
    refute html =~ "25,000"
  end

  test "every other page that names a price names the current one", %{conn: conn} do
    for path <- ~w(/alternatives/builtwith /alternatives/wappalyzer /alternatives/storeleads /terms /tools/tech-lookup /tools/shopify-checker) do
      html = conn |> get(path) |> html_response(200)
      refute html =~ ~r/\$39(?!\d)/, "#{path} still says $39"
      refute html =~ ~r/\$499(?!\d)/, "#{path} still says $499"
    end

    llms = File.read!("priv/static/llms.txt")
    assert llms =~ "$49/month" and llms =~ "$399/month" and llms =~ "$999/month"
    refute llms =~ ~r/\$39(?!\d)/
    assert llms =~ "listsignal_count"
  end

  test "the OpenAPI spec says rows, and lists the free endpoints as free", %{conn: conn} do
    spec = conn |> get(~p"/openapi.json") |> json_response(200)
    assert spec["info"]["description"] =~ "rows a month"
    assert spec["paths"]["/api/v1/count"]["get"]["summary"] =~ "Free"
    assert spec["components"]["securitySchemes"]["bearerAuth"]["description"] =~ "1,000 rows"
    refute spec["info"]["description"] =~ "lookups/month"
  end
end
