defmodule LSWeb.DashboardUrlFiltersTest do
  @moduledoc """
  A dashboard URL that names filters opens as that search (2026-10-27):
  the /data examples, the docs and the outbound plan link to
  `/dashboard?country=AU&tech=Shopify,Klaviyo&tech_not=Gorgias`, and the
  CSV button under the same view carries the same query string. Before
  this the dashboard ignored every URL parameter but `d` and `checkout`.
  """
  use LSWeb.ConnCase

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "the URL's filters become the view's filters, tags and export link", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/dashboard?country=AU&tech=Shopify,Klaviyo&tech_not=Gorgias&has_named_email=true&min_products=300&bogus=1")

    assert html =~ "Gorgias"
    assert html =~ ~s(phx-value-field="tech_not")
    assert html =~ ~s(phx-value-field="has_named_email")

    export = view |> element(~s(a[href^="/dashboard/export"])) |> render()
    assert export =~ "tech_not=Gorgias"
    assert export =~ "has_named_email=true"
    assert export =~ "min_products=300"
    assert export =~ "country=AU"
    refute export =~ "bogus"
  end

  test "a bare URL keeps the default view", %{conn: conn} do
    # The unfiltered view has no export link at all (the whole table is over
    # the file cap), so the check is that no filter reached the page.
    {:ok, view, _} = live(conn, ~p"/dashboard")
    html = render(view)
    refute html =~ "country="
    refute html =~ ~s(phx-value-value="Gorgias")
  end

  test "the new toolbar controls exist for every reachability and stack filter", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/dashboard")
    for field <- ~w(has_named_email has_phone tech_not min_confidence changed_field), do: assert(html =~ ~s(phx-value-field="#{field}"), field)
    assert html =~ ~s(name="keyword")
    assert html =~ ~s(name="first_seen_after")
  end

  test "the outbound presets are one click and carry the grammar's keys", %{conn: conn} do
    ids = Enum.map(LSWeb.ExplorerLive.segments(), & &1.id)
    for id <- ~w(new_stores_west started_hiring replatform_us shopify_agencies), do: assert(id in ids)

    for seg <- LSWeb.ExplorerLive.segments() do
      params = LS.Query.to_params(seg.filters)
      assert length(params) == map_size(seg.filters), "#{seg.id} has a key outside the grammar"
    end

    {:ok, view, _} = live(conn, ~p"/dashboard")
    html = view |> element(~s(button[phx-value-id="started_hiring"])) |> render_click()
    assert html =~ "hr_job_count"
  end
end
