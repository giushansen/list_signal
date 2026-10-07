defmodule LS.Backfill.ReclassifyTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The 2026-10-07 backfill revisits stored homepage blocks so the golden v6
  classifier's withheld labels reach the product table. These pin the pure
  parts: the decision against the served label, the signal map's shape, the
  row written, and the cursor never splitting a domain across batches.
  """

  alias LS.Backfill.Reclassify

  defp biz(over \\ %{}) do
    Map.merge(
      %{domain: "musicacura.com", business_model: "Ecommerce", http_last_checked_at: "2026-08-26 18:34:03", is_junk: "",
        http_title: "Musica Cura", http_h1: "Kommende Veranstaltungen", http_meta_description: "",
        http_nav_links: "HOME|EVENTS", http_tech: "Apache|WooCommerce|WordPress", http_apps: "WPForms",
        http_schema_type: "", http_address: "", http_phone: "", http_pages: "/events", ctl_tld: "com",
        rdap_nameservers: "ns1.dreamhost.com", dns_mx: "mx.dreamhost.com", dns_dmarc: "", dns_dkim: "",
        dns_bimi: "", dns_ms_enterprise: "", last_http_status: 200},
      over
    )
  end

  test "the decision is read against the label the product serves" do
    assert Reclassify.decision("Ecommerce", "Ecommerce") == :same
    assert Reclassify.decision("Ecommerce", "") == :cleared
    assert Reclassify.decision("", "LocalBusiness") == :added
    assert Reclassify.decision("Ecommerce", "Consulting") == :relabeled
    assert Reclassify.decision("", "") == :same
  end

  test "pages the new code already judged, and junk, are left alone" do
    assert Reclassify.eligible?(biz(), "2026-10-05 22:00:00")
    refute Reclassify.eligible?(biz(%{http_last_checked_at: "2026-10-06 01:00:00"}), "2026-10-05 22:00:00")
    refute Reclassify.eligible?(biz(%{is_junk: "parked"}), "2026-10-05 22:00:00")
    # Second pass: only the window the fleet fetched before the fold fix.
    assert Reclassify.eligible?(biz(%{http_last_checked_at: "2026-10-06 01:00:00"}), "2026-10-05 22:00:00", "2026-10-07 03:00:00")
    refute Reclassify.eligible?(biz(), "2026-10-05 22:00:00", "2026-10-07 03:00:00")
  end

  test "the signal map has the classifier's keys and the body is header-first visible text capped at 500" do
    page = %{domain: "musicacura.com", fetched_at: "2026-10-01 00:00:00", header: ["HOME", "EVENTS"], body: [String.duplicate("x", 600)], footer: ["Impressum"]}
    sig = Reclassify.signals(page, biz())

    for k <- ~w(http_tech http_apps http_title http_meta_description http_pages http_schema_type http_og_type ctl_tld dns_txt h1 body_text nav_links http_status is_js_site rdap_nameservers http_address http_phone domain)a do
      assert Map.has_key?(sig, k), "#{k}"
    end

    assert String.starts_with?(sig.body_text, "HOME EVENTS x")
    assert String.length(sig.body_text) == 500
    assert sig.http_status == 200

    # The stale WooCommerce-only label is exactly what the backfill exists to clear.
    assert LS.HTTP.BusinessClassifier.classify(sig).business_model == ""
  end

  test "a verdict is written as a full copy of the newest real enrich_log row with the overrides, never a hollow row" do
    cols = ~w(enriched_at worker domain dns_a dns_mx dns_dmarc http_status http_error http_title http_address business_model industry classification_confidence classification_source http_observed pipeline_version)
    sql = Reclassify.insert_sql(cols, [Reclassify.verdict("musicacura.com", %{business_model: "", industry: "", confidence: 0.33, source: ""}),
                                       Reclassify.verdict("o'neil.com", %{business_model: "SaaS", industry: "HR", confidence: 0.8, source: "heuristic"})])

    assert sql =~ "INSERT INTO enrich_log (enriched_at, worker, domain, dns_a, dns_mx, dns_dmarc, http_status, http_error, http_title, http_address, business_model, industry, classification_confidence, classification_source, http_observed, pipeline_version)"
    assert sql =~ "now() AS enriched_at, 'master' AS worker, d.domain, d.dns_a, d.dns_mx, d.dns_dmarc, CAST(NULL AS Nullable(Int32)) AS http_status, '' AS http_error, d.http_title, d.http_address"
    assert sql =~ "v.bm AS business_model, v.ind AS industry, CAST(v.conf AS Nullable(Float32)) AS classification_confidence, v.src AS classification_source, 0 AS http_observed, 'backfill-"
    assert sql =~ "conf Nullable(Float64), src String'"
    # The source is enrich_log (all columns, so DMARC and the page facts are not blanked), never an earlier backfill row.
    assert sql =~ "FROM (SELECT * FROM enrich_log"
    assert sql =~ "WHERE (domain, enriched_at) IN ("
    assert sql =~ "SELECT domain, max(enriched_at) FROM enrich_log\n        WHERE domain IN ('musicacura.com', 'o\\'neil.com') AND pipeline_version NOT LIKE 'backfill-%' GROUP BY domain"
    # A declined page says none; a quote in a domain is escaped.
    assert sql =~ "('musicacura.com', '', '', 0.33, 'none')"
    assert sql =~ "('o\\'neil.com', 'SaaS', 'HR', 0.8, 'heuristic')"
  end

  test "the cursor never splits a domain whose stored versions straddle two batches" do
    pages = for {d, at} <- [{"a.com", "1"}, {"b.com", "1"}, {"b.com", "2"}, {"c.com", "1"}, {"c.com", "2"}], do: %{domain: d, fetched_at: at}
    {kept, cursor} = Reclassify.trim_split_domain(pages, 5)
    assert Enum.map(kept, & &1.domain) == ["a.com", "b.com"]
    assert Enum.find(kept, &(&1.domain == "b.com")).fetched_at == "2"
    assert cursor == "b.com"

    {kept2, cursor2} = Reclassify.trim_split_domain(pages, 10)
    assert Enum.map(kept2, & &1.domain) == ["a.com", "b.com", "c.com"]
    assert cursor2 == "c.com"
  end
end
