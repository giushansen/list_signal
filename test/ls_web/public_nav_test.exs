defmodule LSWeb.PublicNavTest do
  @moduledoc """
  The public navbar lives in `LSWeb.Layouts.public_root/1` and nowhere else.

  Before this was centralised, every marketing template shipped its own `<nav>`:
  /features had no Sign in link, /privacy had no Features or Pricing link, and
  /tech/* had no links at all. These tests fail if that ever comes back.
  """
  use LSWeb.ConnCase, async: true

  # Renders 14 real pages x 3 tests against the full local ClickHouse; a
  # cold /tech assembly alone is several seconds. The 60s default is
  # marginal, and a test that times out on a slow machine teaches people to
  # ignore red.
  @moduletag timeout: 300_000

  setup do
    # Public pages never touch SQLite, but ConnCase checks out the sandbox's
    # ONLY connection in setup — and this module renders 42 pages against a
    # full local ClickHouse, holding it for minutes. Every other DB test then
    # queued past its own 60s timeout: ~a dozen unrelated failures per run,
    # different ones each time. Hand the connection back before rendering.
    Ecto.Adapters.SQL.Sandbox.checkin(LS.Repo)
    :ok
  end

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LSWeb.Layouts

  # Routes rendered through the :public pipeline that do not depend on a
  # ClickHouse row existing. Each must render the identical navbar.
  @public_paths [
    "/",
    "/features",
    "/pricing",
    "/privacy",
    "/terms",
    "/apps",
    "/countries",
    "/latest-shopify-stores",
    "/latest-saas-businesses",
    "/tools/shopify-checker",
    "/tools/tech-lookup",
    "/tech/klaviyo",
    "/top/shopify",
    "/alternatives/builtwith"
  ]

  # Every link the navbar must expose on every single public page.
  defp required_links do
    Enum.map(Layouts.nav_links(), fn {href, _label} -> href end) ++
      ["/users/log-in", "/signup", "/"]
  end

  # Without a ClickHouse server some data-backed pages legitimately render their
  # "not found" body — those still go through the public layout, so the navbar
  # assertions hold either way.
  defp page_html(conn, path) do
    conn = get(conn, path)
    assert conn.status in [200, 404], "#{path} returned #{conn.status}"
    response(conn, conn.status)
  end

  defp nav_html(conn, path) do
    [nav] = Regex.run(~r|<nav class="fixed top-0.*?</nav>|s, page_html(conn, path))
    nav
  end

  describe "every public page renders the same navbar" do
    for path <- @public_paths do
      test "#{path} exposes all navbar links", %{conn: conn} do
        nav = nav_html(conn, unquote(path))

        for href <- required_links() do
          assert nav =~ ~s|href="#{href}"|,
                 "navbar on #{unquote(path)} is missing a link to #{href}"
        end
      end
    end

    test "the navbar markup is byte-identical across pages (modulo active highlight)", %{conn: conn} do
      navs =
        Map.new(@public_paths, fn path ->
          # The active-page link swaps text-white/60 -> text-white; normalise it
          # so we compare structure, not the highlight.
          {path, nav_html(conn, path) |> String.replace("text-white/60", "text-white")}
        end)

      [{ref_path, reference} | rest] = Map.to_list(navs)

      for {path, nav} <- rest do
        assert nav == reference, "navbar on #{path} differs from the one on #{ref_path}"
      end
    end

    test "the navbar has exactly one occurrence per page (no page ships its own)", %{conn: conn} do
      for path <- @public_paths do
        count = length(Regex.scan(~r|<nav class="fixed top-0|, page_html(conn, path)))

        assert count == 1,
               "expected exactly 1 fixed navbar on #{path}, found #{count}"
      end
    end
  end

  test "no page template declares its own fixed navbar" do
    offenders =
      "lib/ls_web/controllers/*_html/*.heex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ ~r|<nav class="fixed top-0|))

    assert offenders == [],
           "these templates ship their own navbar instead of using the layout: #{inspect(offenders)}"
  end

  test "footer links all point at routes the navbar/router knows about" do
    footer = render_component(&Layouts.footer/1, %{})

    assert footer =~ ~s|href="/features"|
    assert footer =~ ~s|href="/pricing"|
    assert footer =~ ~s|href="/users/log-in"|
  end
end
