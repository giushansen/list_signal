defmodule LS.EnrichmentTest do
  @moduledoc """
  Unit tests for the pipeline-2 analysers.

  All of them parse untrusted third-party HTML/JSON, so every test that matters
  here is about *degrading gracefully*: a missing page, a truncated body or a
  hostile payload must yield empty fields, never an exception — one raising
  analyser would kill a whole enrichment batch.
  """
  use ExUnit.Case, async: true

  alias LS.Enrichment.{SEO, About, Jobs, Shopify}

  describe "SEO.audit/2" do
    @good """
    <html lang="en"><head>
      <title>Acme — Wholesale Coffee Roasters in Portland</title>
      <meta name="description" content="Acme roasts and ships specialty coffee to cafes across the Pacific Northwest. Order wholesale beans with free delivery.">
      <link rel="canonical" href="https://acme.com/">
      <meta name="viewport" content="width=device-width">
      <meta property="og:title" content="Acme"><meta name="twitter:card" content="summary">
      <script type="application/ld+json">{"@type":"Organization"}</script>
    </head><body><h1>Wholesale Coffee</h1>
      <img src="a.jpg" alt="beans"><a href="/shop">Shop</a><a href="https://x.com">X</a>
      <p>#{String.duplicate("word ", 400)}</p>
    </body></html>
    """

    test "scores a well-formed page highly and reports no issues" do
      r = SEO.audit(@good)
      assert r.seo_score >= 90
      assert r.seo_issues == ""
      assert r.seo_word_count > 300
      assert r.seo_alt_ratio == 1.0
      # Link counts were dropped: a raw internal/external tally says nothing
      # about SEO quality on its own, and nobody filtered on it.
      refute Map.has_key?(r, :seo_internal_links)
      refute Map.has_key?(r, :seo_external_links)
    end

    test "names each failing check on a bare page" do
      r = SEO.audit("<html><body><p>hi</p></body></html>")
      assert r.seo_score < 30
      for issue <- ~w(title_missing meta_description_missing h1_missing canonical_missing
                      structured_data_missing thin_content) do
        assert r.seo_issues =~ issue
      end
    end

    test "noindex is penalised (it removes the page from search entirely)" do
      html = ~s(<html><head><meta name="robots" content="noindex"></head><body></body></html>)
      assert SEO.audit(html).seo_issues =~ "robots_noindex"
    end

    test "perf checks only apply when the browser supplied metrics" do
      without = SEO.audit(@good)
      with_slow = SEO.audit(@good, %{lcp_ms: 6000, cls: 0.4, ttfb_ms: 2000})

      assert without.perf_lcp_ms == nil
      refute without.seo_issues =~ "lcp_slow"
      assert with_slow.seo_issues =~ "lcp_slow"
      assert with_slow.seo_issues =~ "cls_high"
      assert with_slow.perf_lcp_ms == 6000
      # A page cannot be punished for metrics we never measured.
      assert without.seo_score > with_slow.seo_score
    end

    test "nil / empty html is safe" do
      assert SEO.audit(nil).seo_score == nil
      assert SEO.audit("").seo_score == nil
    end
  end

  describe "About.analyze/4" do
    test "extracts mission, HQ and position overview without any About page" do
      jobs = [
        %{title: "Senior Backend Engineer", location: "Berlin, Germany"},
        %{title: "Staff Engineer", location: "Berlin, Germany"},
        %{title: "Account Executive", location: "Remote"}
      ]

      careers = """
      <html><body><p>We are on a mission to help small retailers compete with
      the giants by giving them enterprise tooling at a fair price.</p>
      <p>Acme is headquartered in Berlin, Germany and works remotely.</p>
      </body></html>
      """

      r = About.analyze("acme.com", careers, jobs)

      assert r.mission =~ "mission to help small retailers"
      assert r.hq_location =~ "Berlin"
      assert r.job_locations_top =~ "Berlin, Germany:2"
      assert r.positions_overview =~ "(3 open)"
      assert r.positions_overview =~ "Senior"
    end

    test "falls back to the most common job location when no HQ phrase exists" do
      jobs = [%{title: "Engineer", location: "Lisbon"}, %{title: "Designer", location: "Lisbon"}]
      r = About.analyze("acme.com", "<html><body><p>Short.</p></body></html>", jobs)
      assert r.hq_location == "Lisbon"
    end

    test "no careers html and no jobs degrades to empty, not an error" do
      r = About.analyze("acme.com", nil, [])
      assert r.mission == ""
      assert r.positions_overview == ""
    end
  end

  describe "Jobs.analyze/3" do
    test "scrapes job links when there is no recognisable ATS" do
      html = """
      <html><body>
        <a href="/careers/senior-rust-engineer">Senior Rust Engineer</a>
        <a href="/jobs/account-manager">Account Manager</a>
        <a href="/about">About</a>
      </body></html>
      """

      {summary, jobs} = Jobs.analyze("acme.com", html)

      assert summary.job_count == 2
      assert summary.ats_platform == ""
      assert summary.job_departments =~ "Engineering"
      assert Enum.all?(jobs, &(&1.job_id != 0))
    end

    test "job_id is stable across crawls so ReplacingMergeTree dedupes" do
      html = ~s(<a href="/jobs/x">Staff Engineer</a>)
      {_, [a]} = Jobs.analyze("acme.com", html)
      {_, [b]} = Jobs.analyze("acme.com", html)
      assert a.job_id == b.job_id
    end

    test "nil html is safe" do
      assert {%{job_count: 0}, []} = Jobs.analyze("acme.com", nil)
    end

    # The board APIs themselves are fetched over the network (not exercised
    # here); what must not silently rot are the endpoint shapes.
    test "every ATS url builder produces the documented public endpoint" do
      assert Jobs.greenhouse_url("acme") == "https://boards-api.greenhouse.io/v1/boards/acme/jobs"
      assert Jobs.lever_url("acme") == "https://api.lever.co/v0/postings/acme?mode=json"
      assert Jobs.ashby_url("acme") == "https://api.ashbyhq.com/posting-api/job-board/acme"
      assert Jobs.workable_url("acme") =~ "apply.workable.com/api/v1/widget/accounts/acme"
      assert Jobs.smartrecruiters_url("Acme1") == "https://api.smartrecruiters.com/v1/companies/Acme1/postings"
      assert Jobs.recruitee_url("acme") == "https://acme.recruitee.com/api/offers/"
      assert Jobs.bamboohr_url("acme") == "https://acme.bamboohr.com/careers/list"
      assert Jobs.breezy_url("acme") == "https://acme.breezy.hr/json"
    end
  end

  # Three separate prod incidents dropped whole insert batches through this
  # one function: a raw newline (platforms), a negative count, and a
  # backslash in a Shopify product title. It is the single choke point for
  # every biz_* write, so it gets tested directly.
  describe "EnrichmentWriter TSV escaping" do
    test "escapes TabSeparated control characters without shifting columns" do
      row = %{domain: "x.com", title: "60s Print 2pc Set\\", product_count: -2, price: 9.99}
      v = fn col -> LS.Cluster.EnrichmentWriter.tsv_value_public(row, col) end

      # backslash doubled (TabSeparated escape), so the next tab still delimits
      assert v.("title") == "60s Print 2pc Set\\\\"
      # negative value in an unsigned column clamped, not passed through
      assert v.("product_count") == "0"
      # ordinary values untouched
      assert v.("price") == "9.99"
      assert v.("domain") == "x.com"
    end

    test "tabs and newlines become spaces" do
      row = %{title: "a\tb\nc"}
      assert LS.Cluster.EnrichmentWriter.tsv_value_public(row, "title") == "a b c"
    end
  end

  describe "Shopify.shopify?/1" do
    test "detects from the tech string produced by discovery" do
      assert Shopify.shopify?("Shopify|Klaviyo")
      refute Shopify.shopify?("WooCommerce")
      refute Shopify.shopify?(nil)
    end
  end
end
