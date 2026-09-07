defmodule LS.Cluster.EstimateProvenanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  google.com went from "$1B+" to "$10M-$100M" on 2026-09-07 with an evidence
  trail of mail records and a cookie banner. Two defects: the worker's
  estimate never sees Tranco/Majestic (workers hold a bloom, not the ranks;
  the master fills them after), and the compactor took the NEWEST estimate,
  so a sparse recrawl (rank and RDAP lookups served from cache, columns
  empty in the row) replaced a rich one.
  """

  test "the master re-estimates a row after filling the ranks" do
    sparse = %{domain: "example.com", http_status: 200, dns_mx: "10:aspmx.l.google.com", dns_txt: "v=spf1 include:_spf.google.com ~all",
               http_tech: "Nginx|Google Analytics|jQuery", tranco_rank: 1, majestic_rank: 1, majestic_ref_subnets: 500_000,
               rdap_registrar: "MarkMonitor Inc.", ctl_issuer: "Google Trust Services",
               estimated_revenue: "$10M-$100M", estimated_employees: "51-500", revenue_confidence: 0.6, revenue_evidence: "mx:GoogleWorkspace"}
    re = LS.Cluster.Inserter.reestimate(sparse)
    assert re.estimated_revenue == "$1B+", "with rank 1 and MarkMonitor the estimate must be the top bracket"
    assert re.revenue_evidence =~ "tranco:top_1k:1"
  end

  test "a row the estimator cannot judge keeps its stored estimate" do
    row = %{domain: "dead.example", http_status: nil, estimated_revenue: "$1M-$10M", estimated_employees: "11-50", revenue_confidence: 0.5, revenue_evidence: "x"}
    assert LS.Cluster.Inserter.reestimate(row).estimated_revenue == "$1M-$10M"
    assert LS.Cluster.Inserter.reestimate(nil) == nil
  end

  test "the compactor keeps the best-evidenced estimate, newest on ties" do
    src = File.read!("lib/ls/clickhouse.ex")
    for col <- ~w(estimated_revenue estimated_employees revenue_confidence revenue_evidence) do
      assert src =~ "argMaxIf(s_#{col}, (s_revenue_confidence, s_enriched_at), s_estimated_revenue != '') AS #{col}"
    end
    refute src =~ "argMaxIf(s_estimated_revenue, s_enriched_at, s_estimated_revenue != '')"
  end
end
