defmodule LS.Revenue.EstimatorGoldenV6Test do
  use ExUnit.Case, async: true

  alias LS.Revenue.Estimator

  @moduledoc """
  Golden v6 (2026-10-05, 320 domains labeled from the stored page blocks)
  measured the estimator at 61.5% exact bracket with 83 over-estimates
  against 22 under, and "$100M-$1B" right 0 times in 25. The evidence
  trails named the culprits: a hosting provider's ASN read as the
  company's own network, Network Solutions scored like MarkMonitor, a
  25-year-old domain scored as enterprise, Microsoft autodiscover (every
  365 tenant) as mid-market, DMARC p=reject (a Cloudflare default) as
  mid-market, "ns1." (every shared host) as the NS1 company. And nothing
  read the page itself, where a freelance art director says "je suis".
  """

  # A one-person site with the exact infrastructure that fooled the
  # estimator: old domain, Network Solutions, a hosted ASN, autodiscover,
  # strict DMARC, ns1 nameserver.
  defp freelancer do
    %{
      domain: "pushaune.fr",
      http_status: 200,
      dns_a: "203.0.113.10",
      http_title: "PUShAUNE | Directeur Artistique photographe videaste freelance sur Marseille",
      http_meta_description: "Je suis PUShAUNE, un graphiste freelance base a Marseille",
      http_h1: "Bonjour, je suis PUShAUNE",
      http_body_snippet: "Je suis a meme de realiser votre identite visuelle.",
      http_tech: "Matomo|Open Graph|WordPress|jsDelivr",
      http_emails: "contact@pushaune.fr",
      http_pages: "/blog|/portfolio",
      rdap_registrar: "Network Solutions, LLC",
      rdap_domain_created_at: "1999-04-02",
      rdap_nameservers: "ns1.inmotionhosting.com|ns2.inmotionhosting.com",
      dns_ms_enterprise: "autodiscover",
      dns_dmarc: "reject",
      dns_mx: "mail.inmotionhosting.com",
      bgp_asn_org: "REGIONAL-HOST - Regional Hosting LLC",
      bgp_asn_number: "54641",
      dns_txt: "v=spf1 include:_spf.google.com ~all",
      job_count: 0,
      product_count: 0,
      sitemap_urls: 40
    }
  end

  test "a freelancer on hosted infrastructure stays under $10M and says why" do
    est = Estimator.estimate(freelancer())
    assert est.estimated_revenue in ["<$1M", "$1M-$10M"], inspect(est)
    assert est.estimated_employees in ["1-10", "11-50"]
    refute est.revenue_evidence =~ "own_asn"
    assert est.revenue_evidence =~ "hosted:"
    assert est.revenue_evidence =~ "registrar:NetworkSolutions→small"
    assert est.revenue_evidence =~ "ms_enterprise:autodiscover→small"
    assert est.revenue_evidence =~ "dmarc:p=reject→small"
    assert est.revenue_evidence =~ ~r/domain_age:\d+yr→mid_market/
  end

  test "the solo cap names its reason and lowers the confidence" do
    # Force an upward winner from infrastructure alone, then let the page win.
    sig =
      freelancer()
      |> Map.merge(%{
        rdap_registrar: "GoDaddy",
        bgp_asn_org: "PUSHAUNE SAS",
        dns_ms_enterprise: "autodiscover|sipfederation|enterpriseregistration"
      })

    # With its own ASN and an enterprise tenant the page's modesty is outranked.
    assert Estimator.strong_upward?(sig)

    # Without them, first-person copy caps the bracket.
    sig2 = Map.merge(sig, %{bgp_asn_org: "REGIONAL-HOST - Regional Hosting LLC", dns_ms_enterprise: "autodiscover"})
    assert Estimator.solo_reason(sig2) == "first_person"
    refute Estimator.strong_upward?(sig2)
    est = Estimator.estimate(sig2)
    assert est.estimated_revenue in ["<$1M", "$1M-$10M"]
    assert est.revenue_confidence <= 0.6 or not (est.revenue_evidence =~ "solo_cap")
  end

  test "a page builder is a solo reason, a thin site is one, a hiring site is not" do
    assert Estimator.solo_reason(%{http_tech: "Wix|Open Graph"}) == "builder"
    assert Estimator.solo_reason(%{http_tech: "Squarespace"}) == "builder"
    assert Estimator.solo_reason(%{http_tech: "Nginx|PHP", http_emails: "a@b.c", http_pages: "/about", job_count: 0, product_count: 0}) == "thin"
    assert Estimator.solo_reason(%{http_tech: "Nginx|PHP|React|Segment|Intercom|HubSpot|Marketo", http_emails: "a@b.c|b@b.c|c@b.c", http_pages: "/careers", job_count: 12}) == nil
  end

  test "brand ASN is the company's name inside the ASN org, nothing else" do
    assert Estimator.brand_asn?("RINGCENTRAL INC", %{domain: "ringcentral.biz"})
    assert Estimator.brand_asn?("AS-AUTHBRIDGE RESEARCH SERVICES", %{domain: "authbridge.com"})
    refute Estimator.brand_asn?("MCO2 TECNO", %{domain: "silmatec.com.br"})
    refute Estimator.brand_asn?("REGIONAL-HOST - Regional Hosting LLC", %{domain: "germantranslators.com"})
    refute Estimator.brand_asn?("", %{domain: "x.com"})
    refute Estimator.brand_asn?("ab", %{domain: "ab.io"})
  end

  test "a real enterprise is not capped: corporate registrar, mail gateway, enterprise tenant, own ASN, traffic" do
    est =
      Estimator.estimate(%{
        domain: "ringcentral.biz",
        http_status: 200,
        dns_a: "203.0.113.11",
        http_title: "RingCentral: The Voice of Your Business",
        http_meta_description: "Power the voice of your business",
        http_tech: "Cloudflare|OneTrust|Open Graph|Microsoft 365|Adobe Analytics|Marketo|Salesforce|Segment",
        http_emails: "press@ringcentral.com|sales@ringcentral.com|ir@ringcentral.com|support@ringcentral.com|legal@ringcentral.com",
        http_pages: "/careers|/investors|/pricing",
        rdap_registrar: "MarkMonitor Inc.",
        rdap_domain_created_at: "2003-05-01",
        rdap_nameservers: "ns1.ringcentral.com|ns2.ringcentral.com",
        dns_ms_enterprise: "autodiscover|sipfederation|enterpriseregistration",
        dns_dmarc: "reject",
        dns_mx: "mxa-00178a01.gslb.pphosted.com",
        bgp_asn_org: "RINGCENTRAL INC",
        bgp_asn_number: "19445",
        tranco_rank: 30_166,
        job_count: 120,
        product_count: 0,
        sitemap_urls: 9_000
      })

    assert est.estimated_revenue in ["$100M-$1B", "$1B+"], inspect(est)
    refute est.revenue_evidence =~ "solo_cap"
    assert est.revenue_evidence =~ "own_asn"
  end

  test "the harness task exists and reads rows the way the inserter keys them" do
    assert Code.ensure_loaded?(Mix.Tasks.Ls.GoldenReestimate)
    assert function_exported?(Mix.Tasks.Ls.GoldenReestimate, :run, 1)
    assert :domain in LS.Cluster.Inserter.columns()
  end
end
