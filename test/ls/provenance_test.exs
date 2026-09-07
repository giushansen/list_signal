defmodule LS.ProvenanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Every crawl and enrichment row says which build produced it, what the
  detectors saw, and which tier chose the business model (2026-09-06,
  migration 023). Without these a wrong value has a time but no cause.
  """

  test "the build version is a short git sha or the honest fallback" do
    assert LS.Version.sha() =~ ~r/^([0-9a-f]{7,12}|unknown)$/
  end

  describe "LS.HTTP.Fingerprint.build/1" do
    test "keeps the evidence the detectors read, bounded" do
      html = ~s(<html><head><meta name="generator" content="WordPress 6.5"><script src="https://static.klaviyo.com/onsite/js/klaviyo.js"></script><script src="//cdn.shopify.com/s/x.js"></script></head></html>)
      fp = Jason.decode!(LS.HTTP.Fingerprint.build(%{body: html, headers: [{"server", "cloudflare"}, {"x-powered-by", "PHP/8.2"}]}))
      assert fp["hosts"] == ["static.klaviyo.com", "cdn.shopify.com"]
      assert fp["gen"] == "WordPress 6.5"
      assert fp["server"] == "cloudflare"
      assert fp["powered"] == "PHP/8.2"
      assert fp["scripts"] == 2
      assert fp["bytes"] == byte_size(html)
    end

    test "hostile pages never raise and the JSON stays under 2 KB" do
      assert LS.HTTP.Fingerprint.build(nil) == ""
      assert LS.HTTP.Fingerprint.build(%{body: <<255, 0, 1>>, headers: :nope}) |> is_binary()
      many = Enum.map_join(1..500, "", &~s(<script src="https://h#{&1}.example.com/very/long/path/#{String.duplicate("a", 100)}.js"></script>))
      out = LS.HTTP.Fingerprint.build(%{body: many, headers: []})
      assert byte_size(out) <= 2_048
      assert length(Jason.decode!(out)["hosts"]) <= 40
    end
  end

  describe "classification source" do
    test "names the tier that chose the shipped business model" do
      heur = %{business_model: "", industry: "", confidence: 0.0}
      ml = %{business_model: "SaaS", industry: "HR software", ml_confidence: 0.7, ml_bm_confidence: 0.7, ml_industry_confidence: 0.5, ml_source: "head_v3_2026-09-06"}
      assert LS.Pipeline.merge_classification(heur, ml).source == "ml:head_v3_2026-09-06"

      heur2 = %{business_model: "Ecommerce", industry: "Fashion", confidence: 0.8}
      assert LS.Pipeline.merge_classification(heur2, ml).source == "heuristic"

      empty_ml = %{business_model: "", industry: "", ml_confidence: 0.0}
      assert LS.Pipeline.merge_classification(heur, empty_ml).source == ""
    end

    test "the classifier reports its own source" do
      assert File.read!("lib/ls/ml/classifier.ex") =~ "ml_source: ml_source(state)"
    end
  end

  test "every row carries the provenance columns and the compactor folds them" do
    assert :http_fingerprint in LS.Cluster.Inserter.columns()
    assert :pipeline_version in LS.Cluster.Inserter.columns()
    assert :classification_source in LS.Cluster.Inserter.columns()
    assert "pipeline_version" in LS.Cluster.EnrichmentWriter.summary_columns()
    assert "classification_source" in LS.Clickhouse.history_cols()
    assert "pipeline_version" in LS.Clickhouse.history_cols()
    src = File.read!("lib/ls/clickhouse.ex")
    assert src =~ "argMaxIf(s_classification_source, s_enriched_at, s_business_model != '') AS classification_source"
    assert src =~ ~r/INSERT INTO businesses \([^)]*\bclassification_source\b[^)]*\bpipeline_version\b/
    sql = File.read!("clickhouse/migrations/023_provenance.sql")
    for c <- ~w(http_fingerprint pipeline_version classification_source), do: assert(sql =~ c)
  end
end
