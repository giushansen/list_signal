defmodule LS.Cluster.InserterTest do
  use ExUnit.Case, async: false

  @required_columns [
    :enriched_at, :worker, :domain,
    :ctl_tld, :ctl_issuer, :ctl_subdomain_count, :ctl_subdomains,
    :dns_a, :dns_aaaa, :dns_mx, :dns_txt, :dns_cname,
    :http_status, :http_response_time, :http_blocked,
    :http_content_type, :http_tech, :http_apps,
    :http_title, :http_meta_description, :http_pages, :http_emails, :http_error,
    :bgp_ip, :bgp_asn_number, :bgp_asn_org, :bgp_asn_country, :bgp_asn_prefix,
    :inferred_country,
    :rdap_domain_created_at, :rdap_domain_expires_at, :rdap_domain_updated_at,
    :rdap_status, :rdap_error,
    :rdap_registrar, :rdap_registrar_iana_id, :rdap_nameservers,
    :tranco_rank, :majestic_rank, :majestic_ref_subnets,
    :is_malware, :is_phishing, :is_disposable_email
  ]

  @rich_row %{
    enriched_at: "2026-03-19 13:37:53", worker: "worker_dev@127.0.0.1", domain: "stripe.com",
    ctl_tld: "com", ctl_issuer: "DigiCert", ctl_subdomain_count: 5, ctl_subdomains: "api|dash",
    ctl_web_scoring: 3, ctl_budget_scoring: 10, ctl_security_scoring: 7,
    dns_a: "104.18.0.1", dns_aaaa: "", dns_mx: "10:aspmx.l.google.com",
    dns_txt: "v=spf1 include:_spf.google.com ~all", dns_cname: "",
    dns_web_scoring: 1, dns_email_scoring: 0, dns_budget_scoring: 0, dns_security_scoring: 1,
    http_status: 200, http_response_time: 450, http_server: "cloudflare", http_cdn: "cloudflare",
    http_blocked: "", http_content_type: "text/html", http_tech: "React|Stripe.js", http_apps: "Yoast SEO",
    http_tools: "GA|GTM", http_is_js_site: "true", http_title: "Stripe",
    http_meta_description: "Online payments", http_pages: "/pricing", http_emails: "", http_error: "",
    bgp_ip: "104.18.0.1", bgp_asn_number: "13335", bgp_asn_org: "CLOUDFLARENET",
    bgp_asn_country: "US", bgp_asn_prefix: "104.18.0.0/20", inferred_country: "US",
    bgp_web_scoring: 5, bgp_budget_scoring: 3,
    rdap_domain_created_at: "2010-01-11 21:27:57", rdap_domain_expires_at: "2029-01-11 21:27:57",
    rdap_domain_updated_at: "2024-07-15 10:30:00", rdap_registrar: "MarkMonitor Inc.",
    rdap_registrar_iana_id: "292", rdap_nameservers: "ns1.p16.dynect.net|ns2.p16.dynect.net",
    rdap_status: "client transfer prohibited|server transfer prohibited",
    rdap_dnssec: "false", rdap_age_scoring: 10, rdap_registrar_scoring: 20, rdap_error: "",
    tranco_rank: 4521, majestic_rank: 2345, majestic_ref_subnets: 18432,
    is_malware: "", is_phishing: "", is_disposable_email: ""
  }

  @empty_row %{
    enriched_at: "2026-03-19 00:00:00", worker: "", domain: "empty.test",
    ctl_tld: "test", ctl_issuer: "", ctl_subdomain_count: 0, ctl_subdomains: "",
    ctl_web_scoring: 0, ctl_budget_scoring: 0, ctl_security_scoring: 0,
    dns_a: "", dns_aaaa: "", dns_mx: "", dns_txt: "", dns_cname: "",
    dns_web_scoring: 0, dns_email_scoring: 0, dns_budget_scoring: 0, dns_security_scoring: 0,
    http_status: nil, http_response_time: nil, http_server: "", http_cdn: "",
    http_blocked: "", http_content_type: "", http_tech: "", http_apps: "",
    http_is_js_site: "", http_title: "", http_meta_description: "",
    http_pages: "", http_emails: "", http_error: "",
    bgp_ip: "", bgp_asn_number: "", bgp_asn_org: "", bgp_asn_country: "",
    bgp_asn_prefix: "", inferred_country: "", bgp_web_scoring: 0, bgp_budget_scoring: 0,
    rdap_domain_created_at: nil, rdap_domain_expires_at: nil, rdap_domain_updated_at: nil,
    rdap_registrar: "", rdap_registrar_iana_id: "", rdap_nameservers: "",
    rdap_status: "", rdap_dnssec: "", rdap_age_scoring: 0, rdap_registrar_scoring: 0, rdap_error: "",
    tranco_rank: nil, majestic_rank: nil, majestic_ref_subnets: nil,
    is_malware: "", is_phishing: "", is_disposable_email: ""
  }

  test "rich row has all required columns" do
    for c <- @required_columns, do: assert(Map.has_key?(@rich_row, c), "Missing: #{c}")
  end

  test "empty row has all required columns" do
    for c <- @required_columns, do: assert(Map.has_key?(@empty_row, c), "Missing: #{c}")
  end

  test "nullable reputation fields" do
    assert @empty_row.tranco_rank == nil
    assert @empty_row.majestic_rank == nil
    assert @empty_row.majestic_ref_subnets == nil
    assert @rich_row.tranco_rank == 4521
    assert @rich_row.majestic_ref_subnets == 18432
  end

  test "blocklist flags are empty strings when clean" do
    assert @rich_row.is_malware == ""
    assert @rich_row.is_phishing == ""
    assert @rich_row.is_disposable_email == ""
  end

  test "domain is never empty" do
    assert @rich_row.domain != ""
    assert @empty_row.domain != ""
  end
end
