defmodule LSWeb.SitemapCacheTest do
  use ExUnit.Case, async: false

  @moduledoc """
  2026-08-25: /sitemap.xml took 29.5s to render under load — five ClickHouse
  scans per request, only fragments cached. Googlebot gives up around 30s, so
  an uncached sitemap gambles the crawl of all ~11k URLs on the box being
  quiet. The whole rendered XML is now one cache entry.
  """

  test "the rendered sitemap has a cache profile long enough to matter" do
    assert {ttl, _desc} = LS.UICache.profiles()[:sitemap_page]
    assert ttl >= 3_600, "a short TTL rebuilds the 5-scan document all day"
  end

  test "a cached sitemap is served without recomputing — the 29.5s build runs once per TTL" do
    key = :xml
    LS.UICache.invalidate(:sitemap_page, key)

    hits = :counters.new(1, [])

    build = fn ->
      :counters.add(hits, 1, 1)
      "<urlset>cached</urlset>"
    end

    assert LS.UICache.fetch(:sitemap_page, key, build) == "<urlset>cached</urlset>"
    assert LS.UICache.fetch(:sitemap_page, key, build) == "<urlset>cached</urlset>"
    assert :counters.get(hits, 1) == 1, "second request must be a cache hit"

    LS.UICache.invalidate(:sitemap_page, key)
  end
end
