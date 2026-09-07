defmodule LSWeb.BrandTest do
  @moduledoc """
  The ListSignal mark is drawn in one place and served from one set of files.

  Why this is pinned (2026-09-07, brand v1): until then the "logo" was the
  letters LS in a coloured box, hand-written six times with four different
  sizes, two different greens and one gradient, and the tab icon was a
  different drawing again. These tests fail if a letter box comes back, if
  the frozen path is redrawn, if a brand file goes missing from Plug.Static,
  or if the two root layouts stop sharing the same head icons.
  """
  use LSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias LSWeb.BrandComponents

  @frozen_path "M10 11H54 M10 32H23L28 23L36 41L41 32H54 M10 53H54"

  # ── The mark itself ───────────────────────────────────────────────────

  describe "logo_mark/1" do
    test "draws exactly the frozen path, one stroke, round caps, currentColor" do
      assert BrandComponents.mark_path() == @frozen_path

      html = render_component(&BrandComponents.logo_mark/1, %{})
      assert html =~ ~s(viewBox="0 0 64 64")
      assert html =~ ~s(d="#{@frozen_path}")
      assert html =~ ~s(stroke="currentColor")
      assert html =~ ~s(stroke-width="7")
      assert html =~ ~s(stroke-linecap="round")
      assert html =~ ~s(stroke-linejoin="round")
      refute html =~ "gradient"
    end

    test "is decorative by default and an image when labelled" do
      plain = render_component(&BrandComponents.logo_mark/1, %{})
      assert plain =~ ~s(aria-hidden="true")
      refute plain =~ "<title>"

      labelled = render_component(&BrandComponents.logo_mark/1, %{label: "ListSignal"})
      assert labelled =~ ~s(role="img")
      assert labelled =~ "<title>ListSignal</title>"
      refute labelled =~ "aria-hidden"
    end

    test "size sets width and height together" do
      html = render_component(&BrandComponents.logo_mark/1, %{size: 18})
      assert html =~ ~s(width="18")
      assert html =~ ~s(height="18")
    end

    test "the generated mark.svg carries the same path as the inline component" do
      svg = File.read!("priv/static/images/brand/mark.svg")
      # The generator writes the path without spaces between commands.
      assert svg =~ String.replace(@frozen_path, " M", "M")
      assert svg =~ ~s(stroke="currentColor")
    end
  end

  describe "logo_tile/1 and logo_lockup/1" do
    test "the tile is the navbar's 30px accent square with a 20px mark and no gradient" do
      html = render_component(&BrandComponents.logo_tile/1, %{})
      assert html =~ "bg-accent"
      assert html =~ "rounded-lg"
      assert html =~ "height:30px;width:30px"
      assert html =~ ~s(width="20")
      refute html =~ "from-white/20"
      refute html =~ "gradient"
    end

    test "the tile scales box and mark together" do
      html = render_component(&BrandComponents.logo_tile/1, %{size: 16})
      assert html =~ "height:16px;width:16px"
      assert html =~ ~s(width="11")
    end

    test "the lockup is a link with the wordmark in the display font at the navbar size" do
      html = render_component(&BrandComponents.logo_lockup/1, %{})
      assert html =~ ~s(href="/")
      assert html =~ "font-display"
      assert html =~ "font-bold"
      assert html =~ "tracking-tight"
      assert html =~ "text-[21px]"
      assert html =~ "ListSignal"
      assert html =~ ~s(viewBox="0 0 64 64")
    end
  end

  # ── Where it must and must not appear ─────────────────────────────────

  describe "the placeholder letter box is gone" do
    # Every hand-written LS box the 2026-09-07 inventory found, and the
    # gradient overlay the navbar one carried.
    @placeholder ~r/>\s*LS\s*<|from-white\/20/

    test "no template under lib/ renders the letters LS as a logo" do
      offenders =
        Path.wildcard("lib/ls_web/**/*.{ex,heex}")
        |> Enum.filter(&(File.read!(&1) =~ @placeholder))

      assert offenders == [], "placeholder LS box still rendered in: #{inspect(offenders)}"
    end
  end

  describe "every brand file Plug.Static must serve" do
    @served ~w(favicon.ico favicon.svg favicon-16x16.png favicon-32x32.png apple-touch-icon.png
               icon-192.png icon-512.png site.webmanifest og-card.png)

    test "is listed in static_paths/0 and exists on disk" do
      for file <- @served do
        assert file in LSWeb.static_paths(), "#{file} is not in LSWeb.static_paths/0, Plug.Static will 404 it"
        assert File.exists?("priv/static/#{file}"), "priv/static/#{file} is missing"
      end

      assert "images" in LSWeb.static_paths()
      assert File.exists?("priv/static/images/brand/mark.svg")
      assert File.exists?("priv/static/images/brand/tile-green-512.png")
    end

    test "the manifest and theme-color carry the Tailwind ls-dark value" do
      manifest = Jason.decode!(File.read!("priv/static/site.webmanifest"))
      assert manifest["theme_color"] == "#080e1e"
      assert manifest["background_color"] == "#080e1e"
      assert Enum.map(manifest["icons"], & &1["src"]) == ["/icon-192.png", "/icon-512.png"]

      # assets/tailwind.config.js is the source of truth for the colour.
      assert File.read!("assets/tailwind.config.js") =~ ~s("ls-dark": "#080E1E")
    end
  end

  describe "the two root layouts" do
    setup do
      # Public pages never touch SQLite; hand the sandbox connection back so
      # this module does not hold it while ClickHouse-backed pages render.
      Ecto.Adapters.SQL.Sandbox.checkin(LS.Repo)
      :ok
    end

    defp head_assertions(html) do
      assert html =~ ~s(<link rel="icon" href="/favicon.svg" type="image/svg+xml">)
      assert html =~ ~s(sizes="16x16" href="/favicon-16x16.png")
      assert html =~ ~s(sizes="32x32" href="/favicon-32x32.png")
      assert html =~ ~s(href="/favicon.ico")
      assert html =~ ~s(href="/apple-touch-icon.png")
      assert length(Regex.scan(~r/rel="manifest"/, html)) == 1
      assert length(Regex.scan(~r/name="theme-color"/, html)) == 1
      assert html =~ ~s(<meta name="theme-color" content="#080e1e">)
    end

    test "public_root: head icons, og:image with its dimensions, the lockup in the nav", %{conn: conn} do
      html = conn |> get("/") |> html_response(200)
      head_assertions(html)

      assert html =~ ~s(property="og:image" content="https://listsignal.com/og-card.png")
      assert html =~ ~s(property="og:image:width" content="1200")
      assert html =~ ~s(property="og:image:height" content="630")
      assert html =~ ~s(property="og:image:alt" content="ListSignal")

      [nav] = Regex.run(~r/<nav aria-label="Main".*?<\/nav>/s, html) || Regex.run(~r/<nav.*?aria-label="Main".*?<\/nav>/s, html)
      assert nav =~ ~s(viewBox="0 0 64 64")
      assert nav =~ "ListSignal"

      # The layout footer (the one with the WPFooter schema; the home page also
      # ships a per-page footer above it) carries the muted mark beside the
      # copyright line.
      [footer] = Regex.run(~r/<footer[^>]*WPFooter.*?<\/footer>/s, html)
      assert footer =~ ~s(viewBox="0 0 64 64")
    end

    test "root (app layout): the same head icons, no drift", %{conn: conn} do
      html = conn |> get("/users/log-in") |> html_response(200)
      head_assertions(html)
      # The log-in page shows the lockup above the form.
      assert html =~ ~s(viewBox="0 0 64 64")
    end
  end

  test "the OpenAPI info block names the logo for Redoc" do
    spec = LSWeb.OpenapiController.spec()
    assert spec.info[:"x-logo"] == %{url: "https://listsignal.com/images/brand/tile-green-512.png", altText: "ListSignal"}
  end
end
