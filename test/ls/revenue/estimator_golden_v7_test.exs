defmodule LS.Revenue.EstimatorGoldenV7Test do
  @moduledoc """
  Golden v7 (2026-10-19) regressions for the revenue estimator. Baseline on
  v7 before these rules: exact bracket 62.2%, 54 over-estimates, 39 under.
  """
  use ExUnit.Case, async: true

  alias LS.Revenue.Estimator

  describe "corporate floor: large organisations read $10M-$100M on golden v7" do
    test "a Manheim-shaped signal set (traffic, Proofpoint, CSC, UltraDNS) is $1B+, not $10M-$100M" do
      signals = %{
        http_status: 200,
        tranco_rank: 15_904,
        majestic_ref_subnets: 1062,
        rdap_registrar: "CSC Corporate Domains, Inc.",
        dns_mx: "5:mxb-0028a403.gslb.pphosted.com",
        rdap_nameservers: "pdns1.ultradns.net|pdns2.ultradns.net",
        dns_dmarc: "p=reject",
        dns_ms_enterprise: "sipfederation",
        http_tech: "Nginx|WordPress|Google Tag Manager|Open Graph|Adobe Fonts|Yoast SEO|Elementor",
        http_schema_type: "Organization"
      }

      res = Estimator.estimate(signals)
      assert res.estimated_revenue == "$1B+"
      assert res.estimated_employees == "5001+"
      assert res.revenue_evidence =~ "corporate_floor:4_facts"
    end

    test "two facts with one strong one (OneTrust plus a ranked site) floor at $100M-$1B" do
      signals = %{
        http_status: 200,
        tranco_rank: 111_225,
        majestic_rank: 53_388,
        majestic_ref_subnets: 1255,
        dns_mx: "1:aspmx.l.google.com",
        dns_txt: "onetrust-domain-verification=abc",
        dns_dmarc: "p=none",
        http_tech: "Cloudflare|WordPress|Google Tag Manager|Open Graph|Cookiebot|HubSpot|Yoast SEO|WPML"
      }

      res = Estimator.estimate(signals)
      assert res.estimated_revenue == "$100M-$1B"
      assert res.revenue_evidence =~ "corporate_floor:2_facts"
    end

    test "corporate_facts counts kinds, not points, and never counts tenant records or SPF" do
      evidence = [
        {"tranco", "top_100k:51544", :mid_market},
        {"majestic", "top_50k:20540", :enterprise},
        {"ref_subnets", "2232", :mid_market},
        {"ms_enterprise", "sipfederation|enterpriseregistration", :enterprise},
        {"spf_includes", "13", :enterprise},
        {"martech", "Pardot", :enterprise},
        {"compliance", "OneTrust/TrustArc", :enterprise},
        {"cdn", "Fastly", :mid_market}
      ]

      assert Estimator.corporate_facts(evidence) == MapSet.new(["traffic", "martech", "compliance"])
      assert Estimator.corporate_facts([{"tranco", "top_1k:364", :large_enterprise}]) == MapSet.new(["traffic", "top_traffic"])
      assert Estimator.corporate_facts([]) == MapSet.new()
      assert Estimator.corporate_facts(nil) == MapSet.new()
    end

    test "a news site that only ranks high stays where its other signals put it" do
      evidence = [{"tranco", "top_100k:16940", :mid_market}, {"majestic", "top_5k:4257", :large_enterprise}, {"ref_subnets", "5865", :enterprise}]
      assert MapSet.size(Estimator.corporate_facts(evidence)) == 1
    end
  end

  describe "Microsoft 365 defaults are not an enterprise vote" do
    test "a plumber on Microsoft 365 with the wizard's two records is not $10M-$100M" do
      signals = %{
        http_status: 200,
        dns_mx: "0:felixplomberie-fr.mail.protection.outlook.com",
        dns_ms_enterprise: "sipfederation|enterpriseregistration",
        dns_dkim: "selector1|selector2",
        dns_dmarc: "p=none",
        http_tech: "Cloudflare|Open Graph|Microsoft 365",
        http_emails: "contact@felixplomberie.fr",
        http_phone: "06 86 44 26 22",
        http_address: "8 rue Vert Castel, 33700 Mérignac",
        rdap_domain_created_at: "2020-03-01T00:00:00Z"
      }

      res = Estimator.estimate(signals)
      assert res.estimated_revenue in ["<$1M", "$1M-$10M"], "got #{res.estimated_revenue}: #{res.revenue_evidence}"
    end
  end

  describe "small cap: $1M-$10M needs one concrete sign of a second person" do
    @thin %{
      http_status: 200,
      dns_mx: "1:aspmx.l.google.com",
      dns_dmarc: "p=none",
      dns_dkim: "google",
      http_tech: "Cloudflare|Google Fonts|Next.js|Open Graph|Google Tag Manager|Vercel",
      rdap_nameservers: "ns1.cloudflare.com|ns2.cloudflare.com",
      http_schema_type: "WebSite",
      http_emails: ""
    }

    test "a six-technology site with no contact data and no rank is under $1M" do
      res = Estimator.estimate(@thin)
      assert res.estimated_revenue == "<$1M", "got #{res.estimated_revenue}: #{res.revenue_evidence}"
      assert res.revenue_evidence =~ "small_cap:no_substance"
    end

    test "two contact emails keep the small bracket" do
      res = Estimator.estimate(%{@thin | http_emails: "sales@acme.test|support@acme.test"})
      refute res.revenue_evidence =~ "small_cap"
    end

    test "small_substance? is pure and reads any of the four signs" do
      refute Estimator.small_substance?(%{})
      assert Estimator.small_substance?(%{http_emails: "a@x.test|b@x.test"})
      assert Estimator.small_substance?(%{http_address: "1 Main St", http_phone: "555"})
      assert Estimator.small_substance?(%{tranco_rank: 900_000})
      refute Estimator.small_substance?(%{tranco_rank: 0, http_address: "1 Main St"})
    end
  end
end
