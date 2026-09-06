defmodule LS.Enrichment.SitemapTest do
  use ExUnit.Case, async: true

  alias LS.Enrichment.Sitemap
  alias LS.HTTP.Robots

  @moduledoc "Sitemap snapshot (2026-09-06): size, shape, freshness and a fingerprint, over hostile XML."

  @plain """
  <?xml version="1.0"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://acme.com/</loc><lastmod>2026-08-01</lastmod></url>
  <url><loc>https://acme.com/products/red-shoe</loc><lastmod>2026-09-02</lastmod></url>
  <url><loc>https://acme.com/products/blue-shoe</loc></url>
  <url><loc>https://acme.com/blog/hello</loc><lastmod>2025-01-01</lastmod></url>
  </urlset>
  """

  @index """
  <sitemapindex><sitemap><loc>https://acme.com/sitemap_products_1.xml</loc></sitemap>
  <sitemap><loc>https://acme.com/sitemap_products_2.xml</loc></sitemap>
  <sitemap><loc>https://acme.com/sitemap_pages.xml</loc></sitemap>
  <sitemap><loc>https://acme.com/sitemap_blogs.xml</loc></sitemap>
  <sitemap><loc>https://acme.com/sitemap_more.xml</loc></sitemap></sitemapindex>
  """

  test "a plain sitemap yields counts, newest lastmod and a hash" do
    s = Sitemap.summarise(@plain, fn _ -> :error end)
    assert s.sitemap_urls == 4
    assert s.sitemap_products == 2
    assert s.sitemap_blog == 1
    assert s.sitemap_children == 0
    assert s.sitemap_lastmod == "2026-09-02 00:00:00"
    assert is_integer(s.sitemap_hash)
  end

  test "an index samples children and extrapolates the total" do
    s = Sitemap.summarise(@index, fn _ -> {:ok, @plain} end)
    assert s.sitemap_children == 5
    # 3 children read (4 URLs each = 12) out of 5 -> 20
    assert s.sitemap_urls == 20
    assert s.sitemap_products == 6
  end

  test "the fingerprint is stable under small churn and flips on a restructure" do
    base = Enum.map(1..200, &"/products/item-#{&1}")
    h1 = Sitemap.simhash(base)
    h2 = Sitemap.simhash(base ++ ["/products/item-201", "/blog/new"])
    other = Sitemap.simhash(Enum.map(1..200, &"/collections/all/things-#{&1}"))
    hamming = fn a, b ->
      x = Bitwise.bxor(a, b)
      Enum.count(0..63, fn bit -> Bitwise.band(Bitwise.bsr(x, bit), 1) == 1 end)
    end

    assert hamming.(h1, h2) <= 8
    assert hamming.(h1, other) >= 16
  end

  test "hostile bodies never raise" do
    assert Sitemap.summarise(nil, fn _ -> :error end) == Sitemap.empty()
    assert Sitemap.summarise(<<255, 0>>, fn _ -> :error end).sitemap_urls == 0
    huge = "<urlset>" <> String.duplicate("<url><loc>https://acme.com/p</loc></url>", 120_000)
    assert Sitemap.summarise(huge, fn _ -> :error end).sitemap_urls <= 50_000
    assert Sitemap.summarise("<sitemapindex>" <> String.duplicate("<sitemap><loc>x</loc></sitemap>", 5_000), fn _ -> :error end).sitemap_children <= 500
  end

  test "only same-host sitemap URLs are followed" do
    assert Sitemap.same_host_path("https://www.acme.com/sitemap.xml?x=1", "acme.com") == "/sitemap.xml?x=1"
    assert Sitemap.same_host_path("https://cdn.other.com/sitemap.xml", "acme.com") == nil
    assert Sitemap.same_host_path("garbage", "acme.com") == nil
    assert Sitemap.same_host_path(nil, "acme.com") == nil
  end

  test "robots.txt Sitemap lines are captured and remembered per domain" do
    body = "User-agent: *\nDisallow:\nSitemap: https://acme.com/sitemap_index.xml\nsitemap:https://acme.com/other.xml\n"
    assert Robots.sitemaps(body) == ["https://acme.com/sitemap_index.xml", "https://acme.com/other.xml"]
    assert Robots.sitemaps(nil) == []
    Robots.remember_sitemaps("sm.example", Robots.sitemaps(body))
    assert Robots.sitemaps_for("sm.example") == ["https://acme.com/sitemap_index.xml", "https://acme.com/other.xml"]
    assert Robots.sitemaps_for("nobody.example") == []
  end
end
