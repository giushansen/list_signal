defmodule LS.PipelinePagesBarTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-03: the page store kept blocks only for sites classified at 0.6 or
  better, 264K of 933K daily 2xx pages, and dropped the 446K pages the
  classifier abstained on, which are the pages a better classifier needs.
  Now every observed, non-junk page keeps its blocks, classified or not.
  """

  @html "<html><head><title>Atelier Dupont</title></head><body><header><nav><a href=/shop>Shop</a></nav></header><main><h1>Handmade lamps</h1><p>We make lamps in Lyon since 2009.</p></main><footer><p>Atelier Dupont SARL, 12 rue des Lampes, 69001 Lyon</p></footer></body></html>"

  defp row(overrides) do
    Map.merge(
      %{domain: "atelier-dupont.example", http_status: 200, is_junk: "", business_model: "", classification_confidence: 0.31,
        enriched_at: "2026-10-03 10:00:00", _page_parts: LS.HTTP.PageBlocks.extract(@html)},
      overrides
    )
  end

  test "an unclassified 2xx page keeps its blocks" do
    out = LS.Pipeline.finalize_pages(row(%{}))
    assert [%{page_kind: "home"} | _] = out[:_pages]
    refute Map.has_key?(out, :_page_parts), "the parsed page must never travel to the master"
  end

  test "a classified page keeps them as before" do
    out = LS.Pipeline.finalize_pages(row(%{business_model: "Ecommerce", classification_confidence: 0.9}))
    assert is_list(out[:_pages])
  end

  test "junk and failed fetches keep nothing" do
    refute Map.has_key?(LS.Pipeline.finalize_pages(row(%{is_junk: "parked"})), :_pages)
    refute Map.has_key?(LS.Pipeline.finalize_pages(row(%{http_status: 503})), :_pages)
    refute Map.has_key?(LS.Pipeline.finalize_pages(row(%{http_status: nil})), :_pages)
    refute Map.has_key?(LS.Pipeline.finalize_pages(row(%{_page_parts: nil})), :_pages)
  end
end
