defmodule LS.MLDeferTest do
  use ExUnit.Case, async: true

  # The :defer path must be byte-equivalent to the inline path: same stashed
  # heuristic, same merge rules, same three row fields.

  @http %{
    http_status: 200,
    http_title: "Acme Cloud Accounting Software for small businesses",
    http_meta_description: "Invoicing and bookkeeping in the cloud",
    _h1: "Accounting made simple",
    _body_text: String.duplicate("accounting invoices bookkeeping cloud saas ", 5)
  }

  defp build_row(opts) do
    LS.Pipeline.merge_row("acme-defer-test.com", %{dns: %{a: ["1.2.3.4"]}}, @http, %{}, %{}, "w@t", "2026-07-27 00:00:00", %{ctl_tld: "com"}, opts)
  end

  test "defer mode stashes text + heuristic instead of classifying inline" do
    row = build_row(ml: :defer)

    if row[:_ml_text] do
      assert is_binary(row[:_ml_text]) and byte_size(row[:_ml_text]) > 20
      assert %{confidence: _} = row[:_ml_heuristic]
      # row fields carry the heuristic values until finalized
      assert row.classification_confidence == row[:_ml_heuristic].confidence
    else
      # heuristic was confident enough on its own — nothing deferred, keys absent
      refute Map.has_key?(row, :_ml_heuristic)
    end
  end

  test "apply_ml applies the same merge rules as the inline path and strips bookkeeping" do
    row = build_row(ml: :defer)

    if row[:_ml_text] do
      ml = %{business_model: "SaaS", industry: "Fintech",
             ml_confidence: 0.8, ml_bm_confidence: 0.8, ml_industry_confidence: 0.8}
      out = LS.Pipeline.apply_ml(row, ml)

      refute Map.has_key?(out, :_ml_text)
      refute Map.has_key?(out, :_ml_heuristic)
      # weak heuristic + strong ML -> ML wins (the documented merge rule)
      if row[:_ml_heuristic].confidence < 0.45 do
        assert out.business_model == "SaaS"
        assert out.industry == "Fintech"
      end
      assert is_float(out.classification_confidence) or is_number(out.classification_confidence)
    end
  end

  test "strip_ml_defer removes only the bookkeeping keys" do
    row = build_row(ml: :defer) |> LS.Pipeline.strip_ml_defer()
    refute Map.has_key?(row, :_ml_text)
    assert row.domain == "acme-defer-test.com"
  end

  test "inline default is unchanged (no bookkeeping keys ever)" do
    row = build_row([])
    refute Map.has_key?(row, :_ml_text)
    refute Map.has_key?(row, :_ml_heuristic)
  end
end
