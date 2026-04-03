defmodule LS.Revenue.EstimatorTest do
  use ExUnit.Case, async: true

  alias LS.Revenue.Estimator

  defp signals(overrides \\ %{}) do
    %{
      domain: "example.com",
      http_status: 200,
      tranco_rank: nil, majestic_rank: nil, majestic_ref_subnets: nil,
      rdap_registrar: "", ctl_issuer: "", dns_mx: "", dns_txt: "",
      http_tech: "", http_apps: "", http_pages: "",
      ctl_subdomain_count: nil, rdap_domain_created_at: "",
      bgp_asn_org: "", bgp_asn_number: "",
      business_model: "", industry: ""
    }
    |> Map.merge(overrides)
  end

  describe "edge cases" do
    test "nil input → empty result" do
      r = Estimator.estimate(nil)
      assert r.estimated_revenue == ""
      assert r.revenue_confidence == 0.0
    end

    test "empty signals → empty result (insufficient evidence)" do
      r = Estimator.estimate(signals())
      assert r.estimated_revenue == ""
    end

    test "non-map input → empty result" do
      assert Estimator.estimate("not a map").estimated_revenue == ""
    end

    test "confidence never exceeds 0.99" do
      r = Estimator.estimate(signals(%{
        tranco_rank: 500,
        rdap_registrar: "MarkMonitor, Inc.",
        ctl_issuer: "DigiCert Inc",
        dns_mx: "pphosted.com",
        dns_txt: "v=spf1 include:a include:b include:c include:d include:e include:f include:g include:h include:i ~all v=DMARC1; p=reject",
        http_tech: "Akamai|Sitecore|Adobe Analytics|Segment|Zendesk",
        ctl_subdomain_count: 600,
        rdap_domain_created_at: "1995-01-01"
      }))
      assert r.revenue_confidence <= 0.99
    end
  end

  describe "Signal: Tranco rank" do
    test "top 1K → large_enterprise" do
      r = Estimator.estimate(signals(%{
        tranco_rank: 500,
        rdap_registrar: "MarkMonitor, Inc.",
        dns_mx: "pphosted.com",
        dns_txt: "v=spf1 include:a include:b include:c ~all"
      }))
      assert r.estimated_revenue == "$1B+"
    end

    test "beyond 1M → micro tendency" do
      r = Estimator.estimate(signals(%{
        tranco_rank: 5_000_000,
        rdap_registrar: "GoDaddy.com, LLC",
        ctl_issuer: "R3",
        dns_mx: "secureserver.net"
      }))
      assert r.estimated_revenue == "<$1M"
    end
  end

  describe "Signal: Registrar" do
    test "MarkMonitor → large_enterprise signal" do
      r = Estimator.estimate(signals(%{
        rdap_registrar: "MarkMonitor, Inc.",
        tranco_rank: 2_000,
        dns_mx: "outlook.protection.com",
        dns_txt: "v=spf1 include:a include:b include:c ~all"
      }))
      assert r.estimated_revenue in ["$100M-$1B", "$1B+"]
    end

    test "GoDaddy → micro signal" do
      r = Estimator.estimate(signals(%{
        rdap_registrar: "GoDaddy.com, LLC",
        ctl_issuer: "R3",
        dns_mx: "secureserver.net",
        dns_txt: "v=spf1 include:_spf.google.com ~all"
      }))
      assert r.estimated_revenue in ["<$1M", "$1M-$10M"]
    end
  end

  describe "Signal: Marketing Automation" do
    test "Marketo in SPF → enterprise signal" do
      r = Estimator.estimate(signals(%{
        dns_txt: "v=spf1 include:mktomail.com include:_spf.google.com ~all v=DMARC1; p=reject",
        dns_mx: "outlook.protection.com",
        tranco_rank: 80_000,
        ctl_issuer: "DigiCert Inc"
      }))
      assert r.estimated_revenue in ["$10M-$100M", "$100M-$1B"]
    end

    test "Mailchimp → micro/small signal" do
      r = Estimator.estimate(signals(%{
        dns_txt: "v=spf1 include:servers.mcsv.net ~all",
        dns_mx: "aspmx.l.google.com",
        ctl_issuer: "R3",
        rdap_registrar: "GoDaddy.com, LLC"
      }))
      assert r.estimated_revenue == "<$1M"
    end
  end

  describe "Signal: CMS" do
    test "Sitecore → enterprise signal" do
      r = Estimator.estimate(signals(%{
        http_tech: "Sitecore|Akamai|jQuery",
        tranco_rank: 40_000,
        dns_mx: "outlook.protection.com",
        dns_txt: "v=spf1 include:a include:b include:c include:d include:e ~all v=DMARC1; p=reject"
      }))
      assert r.estimated_revenue in ["$100M-$1B", "$1B+"]
    end

    test "Wix → micro signal" do
      r = Estimator.estimate(signals(%{
        http_tech: "Wix",
        ctl_issuer: "R3",
        dns_mx: "aspmx.l.google.com",
        dns_txt: "v=spf1 include:_spf.google.com ~all",
        rdap_registrar: "GoDaddy.com, LLC"
      }))
      assert r.estimated_revenue == "<$1M"
    end
  end

  describe "realistic combined scenarios" do
    test "Fortune 500 company" do
      r = Estimator.estimate(signals(%{
        tranco_rank: 300,
        rdap_registrar: "MarkMonitor, Inc.",
        ctl_issuer: "DigiCert Inc",
        dns_mx: "mx1.pphosted.com",
        dns_txt: "v=spf1 include:mktomail.com include:_spf.salesforce.com include:_spf.google.com include:mail.zendesk.com include:_netblocks.mimecast.com ~all v=DMARC1; p=reject",
        http_tech: "Akamai|React|Next.js|Segment|Zendesk|Google Analytics",
        http_pages: "/enterprise|/careers|/security|/partners",
        ctl_subdomain_count: 350,
        rdap_domain_created_at: "1998-09-15",
        bgp_asn_org: "STRIPE, INC.",
        bgp_asn_number: "AS396982"
      }))
      assert r.estimated_revenue in ["$100M-$1B", "$1B+"]
      assert r.revenue_confidence >= 0.70
      assert r.revenue_evidence =~ "tranco"
      assert r.revenue_evidence =~ "registrar"
      assert r.estimated_employees in ["501-5000", "5001+"]
    end

    test "small Shopify store" do
      r = Estimator.estimate(signals(%{
        tranco_rank: nil,
        rdap_registrar: "GoDaddy.com, LLC",
        ctl_issuer: "R3",
        dns_mx: "aspmx.l.google.com",
        dns_txt: "v=spf1 include:_spf.google.com ~all",
        http_tech: "Shopify|Google Analytics|jQuery",
        http_apps: "Klaviyo|Judge.me|Afterpay",
        http_pages: "/cart|/collections|/products",
        ctl_subdomain_count: 2,
        rdap_domain_created_at: "2020-06-01",
        business_model: "Ecommerce",
        industry: "Fashion"
      }))
      assert r.estimated_revenue in ["<$1M", "$1M-$10M"]
    end

    test "micro freelancer site" do
      r = Estimator.estimate(signals(%{
        tranco_rank: nil,
        rdap_registrar: "Namecheap, Inc.",
        ctl_issuer: "R3",
        dns_mx: "registrar-servers.com",
        dns_txt: "",
        http_tech: "WordPress",
        http_apps: "",
        http_pages: "/about|/contact",
        ctl_subdomain_count: 1,
        rdap_domain_created_at: "2022-08-20",
        bgp_asn_org: "NAMECHEAP-NET"
      }))
      assert r.estimated_revenue == "<$1M"
    end
  end

  describe "Signal: Subdomain names" do
    test "dev/staging/api subdomains boost mid_market" do
      r = Estimator.estimate(signals(%{
        ctl_subdomains: "api|staging|dev|docs",
        dns_mx: "aspmx.l.google.com",
        ctl_issuer: "R3",
        dns_txt: "v=spf1 include:_spf.google.com ~all",
        rdap_registrar: "Cloudflare, Inc."
      }))
      assert r.revenue_evidence =~ "subnames"
    end
  end

  describe "Signal: Nameservers" do
    test "UltraDNS → enterprise signal" do
      r = Estimator.estimate(signals(%{
        rdap_nameservers: "pdns1.ultradns.net|pdns2.ultradns.net",
        tranco_rank: 50_000,
        dns_mx: "outlook.protection.com",
        dns_txt: "v=spf1 include:a include:b include:c ~all v=DMARC1; p=reject"
      }))
      assert r.revenue_evidence =~ "UltraDNS"
    end

    test "registrar default nameservers → micro signal" do
      r = Estimator.estimate(signals(%{
        rdap_nameservers: "ns1.domaincontrol.com|ns2.domaincontrol.com",
        rdap_registrar: "GoDaddy.com, LLC",
        ctl_issuer: "R3",
        dns_mx: "secureserver.net"
      }))
      assert r.estimated_revenue == "<$1M"
    end
  end

  describe "Signal: DNS load balancing" do
    test "many A records boost enterprise" do
      r = Estimator.estimate(signals(%{
        dns_a: "1.1.1.1|2.2.2.2|3.3.3.3|4.4.4.4|5.5.5.5|6.6.6.6|7.7.7.7|8.8.8.8",
        tranco_rank: 30_000,
        rdap_registrar: "MarkMonitor, Inc.",
        dns_mx: "pphosted.com",
        dns_txt: "v=spf1 include:a include:b include:c ~all"
      }))
      assert r.revenue_evidence =~ "dns_lb"
    end
  end

  describe "Signal: Industry prior" do
    test "Finance industry boosts mid_market" do
      r = Estimator.estimate(signals(%{
        industry: "Finance",
        tranco_rank: 200_000,
        dns_mx: "outlook.protection.com",
        ctl_issuer: "DigiCert Inc",
        dns_txt: "v=spf1 include:a include:b include:c ~all v=DMARC1; p=reject"
      }))
      assert r.revenue_evidence =~ "Finance"
    end
  end

  describe "evidence trail" do
    test "evidence includes signal names and values" do
      r = Estimator.estimate(signals(%{
        tranco_rank: 5_000,
        rdap_registrar: "MarkMonitor, Inc.",
        dns_mx: "pphosted.com",
        dns_txt: "v=spf1 include:a include:b include:c ~all"
      }))
      assert r.revenue_evidence =~ "tranco"
      assert r.revenue_evidence =~ "registrar"
      assert r.revenue_evidence =~ "MarkMonitor"
    end

    test "evidence uses pipe separator and arrows" do
      r = Estimator.estimate(signals(%{
        tranco_rank: 5_000,
        rdap_registrar: "MarkMonitor, Inc.",
        ctl_issuer: "DigiCert Inc",
        dns_mx: "pphosted.com",
        dns_txt: "v=spf1 include:a include:b include:c ~all"
      }))
      assert r.revenue_evidence =~ "|"
      assert r.revenue_evidence =~ "→"
    end
  end

  describe "bracket labels" do
    test "bracket_label returns correct strings" do
      assert Estimator.bracket_label(:micro) == "<$1M"
      assert Estimator.bracket_label(:small) == "$1M-$10M"
      assert Estimator.bracket_label(:mid_market) == "$10M-$100M"
      assert Estimator.bracket_label(:enterprise) == "$100M-$1B"
      assert Estimator.bracket_label(:large_enterprise) == "$1B+"
    end
  end
end
