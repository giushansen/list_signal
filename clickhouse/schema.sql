-- ============================================================================
-- LISTSIGNAL CLICKHOUSE SCHEMA v3 — RDAP + REPUTATION
-- ============================================================================
CREATE DATABASE IF NOT EXISTS ls;

CREATE TABLE IF NOT EXISTS ls.enrichments
(
    enriched_at DateTime DEFAULT now(),
    worker LowCardinality(String) DEFAULT '',
    -- CTL
    domain String,
    ctl_tld LowCardinality(String) DEFAULT '',
    ctl_issuer LowCardinality(String) DEFAULT '',
    ctl_subdomain_count Nullable(Int32),
    ctl_subdomains String DEFAULT '',
    ctl_web_scoring Nullable(Int32),
    ctl_budget_scoring Nullable(Int32),
    ctl_security_scoring Nullable(Int32),
    -- DNS
    dns_a String DEFAULT '',
    dns_aaaa String DEFAULT '',
    dns_mx String DEFAULT '',
    dns_txt String DEFAULT '',
    dns_cname String DEFAULT '',
    dns_web_scoring Nullable(Int32),
    dns_email_scoring Nullable(Int32),
    dns_budget_scoring Nullable(Int32),
    dns_security_scoring Nullable(Int32),
    -- HTTP
    http_status Nullable(Int32),
    http_response_time Nullable(Int32),
    http_server LowCardinality(String) DEFAULT '',
    http_cdn LowCardinality(String) DEFAULT '',
    http_blocked LowCardinality(String) DEFAULT '',
    http_content_type LowCardinality(String) DEFAULT '',
    http_tech String DEFAULT '',
    http_tools String DEFAULT '',
    http_is_js_site LowCardinality(String) DEFAULT '',
    http_title String DEFAULT '',
    http_meta_description String DEFAULT '',
    http_pages String DEFAULT '',
    http_emails String DEFAULT '',
    http_error LowCardinality(String) DEFAULT '',
    -- BGP
    bgp_ip String DEFAULT '',
    bgp_asn_number LowCardinality(String) DEFAULT '',
    bgp_asn_org LowCardinality(String) DEFAULT '',
    bgp_asn_country LowCardinality(String) DEFAULT '',
    bgp_asn_prefix String DEFAULT '',
    bgp_web_scoring Nullable(Int32),
    bgp_budget_scoring Nullable(Int32),
    -- RDAP
    rdap_domain_created_at Nullable(DateTime),
    rdap_domain_expires_at Nullable(DateTime),
    rdap_domain_updated_at Nullable(DateTime),
    rdap_registrar LowCardinality(String) DEFAULT '',
    rdap_registrar_iana_id LowCardinality(String) DEFAULT '',
    rdap_nameservers String DEFAULT '',
    rdap_status String DEFAULT '',
    rdap_dnssec LowCardinality(String) DEFAULT '',
    rdap_age_scoring Nullable(Int32),
    rdap_registrar_scoring Nullable(Int32),
    rdap_error LowCardinality(String) DEFAULT '',
    -- Reputation
    tranco_rank Nullable(Int32),
    majestic_rank Nullable(Int32),
    majestic_ref_subnets Nullable(Int32),
    is_malware LowCardinality(String) DEFAULT '',
    is_phishing LowCardinality(String) DEFAULT '',
    is_disposable_email LowCardinality(String) DEFAULT ''
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(enriched_at)
ORDER BY (domain, enriched_at)
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS ls.domains_current
ENGINE = ReplacingMergeTree(enriched_at)
ORDER BY domain
SETTINGS index_granularity = 8192
AS SELECT
    enriched_at, worker, domain,
    ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains,
    ctl_web_scoring, ctl_budget_scoring, ctl_security_scoring,
    dns_a, dns_aaaa, dns_mx, dns_txt, dns_cname,
    dns_web_scoring, dns_email_scoring, dns_budget_scoring, dns_security_scoring,
    http_status, http_response_time, http_server, http_cdn, http_blocked,
    http_content_type, http_tech, http_tools, http_is_js_site,
    http_title, http_meta_description, http_pages, http_emails, http_error,
    bgp_ip, bgp_asn_number, bgp_asn_org, bgp_asn_country, bgp_asn_prefix,
    bgp_web_scoring, bgp_budget_scoring,
    rdap_domain_created_at, rdap_domain_expires_at, rdap_domain_updated_at,
    rdap_registrar, rdap_registrar_iana_id, rdap_nameservers,
    rdap_status, rdap_dnssec, rdap_age_scoring, rdap_registrar_scoring, rdap_error,
    tranco_rank, majestic_rank, majestic_ref_subnets,
    is_malware, is_phishing, is_disposable_email,
    -- Computed scores
    ifNull(ctl_web_scoring,0) + ifNull(dns_web_scoring,0) + ifNull(bgp_web_scoring,0) AS total_web_scoring,
    ifNull(ctl_budget_scoring,0) + ifNull(dns_budget_scoring,0) + ifNull(bgp_budget_scoring,0) + ifNull(rdap_registrar_scoring,0) AS total_budget_scoring,
    ifNull(ctl_security_scoring,0) + ifNull(dns_security_scoring,0) AS total_security_scoring,
    ifNull(rdap_age_scoring,0) AS total_age_scoring
FROM ls.enrichments;
