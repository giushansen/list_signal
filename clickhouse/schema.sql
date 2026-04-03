-- ============================================================================
-- LISTSIGNAL CLICKHOUSE SCHEMA
-- Source of truth. Matches LS.Cluster.Inserter.@columns exactly (54 columns).
-- Run: clickhouse client < clickhouse/schema.sql
-- Reset: bash clickhouse/setup.sh
-- ============================================================================

CREATE DATABASE IF NOT EXISTS ls;

-- Append-only log. Every enriched domain gets a row here.
-- Partitioned by month for cheap retention management (DROP PARTITION).
CREATE TABLE IF NOT EXISTS ls.enrichments
(
    -- Meta (3)
    enriched_at DateTime DEFAULT now(),
    worker LowCardinality(String) DEFAULT '',
    domain String,

    -- CTL — Certificate Transparency (4)
    ctl_tld LowCardinality(String) DEFAULT '',
    ctl_issuer LowCardinality(String) DEFAULT '',
    ctl_subdomain_count Nullable(Int32),
    ctl_subdomains String DEFAULT '',

    -- DNS (5)
    dns_a String DEFAULT '',
    dns_aaaa String DEFAULT '',
    dns_mx String DEFAULT '',
    dns_txt String DEFAULT '',
    dns_cname String DEFAULT '',

    -- HTTP (14)
    http_status Nullable(Int32),
    http_response_time Nullable(Int32),
    http_blocked LowCardinality(String) DEFAULT '',
    http_content_type LowCardinality(String) DEFAULT '',
    http_tech String DEFAULT '',
    http_apps String DEFAULT '',
    http_language LowCardinality(String) DEFAULT '',
    http_title String DEFAULT '',
    http_meta_description String DEFAULT '',
    http_pages String DEFAULT '',
    http_emails String DEFAULT '',
    http_error LowCardinality(String) DEFAULT '',
    http_h1 String DEFAULT '',
    http_body_snippet String DEFAULT '',

    -- Classification (5)
    business_model LowCardinality(String) DEFAULT '',
    industry LowCardinality(String) DEFAULT '',
    classification_confidence Nullable(Float32),
    http_schema_type LowCardinality(String) DEFAULT '',
    http_og_type LowCardinality(String) DEFAULT '',

    -- BGP (5)
    bgp_ip String DEFAULT '',
    bgp_asn_number LowCardinality(String) DEFAULT '',
    bgp_asn_org LowCardinality(String) DEFAULT '',
    bgp_asn_country LowCardinality(String) DEFAULT '',
    bgp_asn_prefix String DEFAULT '',

    -- RDAP (8)
    rdap_domain_created_at Nullable(DateTime),
    rdap_domain_expires_at Nullable(DateTime),
    rdap_domain_updated_at Nullable(DateTime),
    rdap_registrar LowCardinality(String) DEFAULT '',
    rdap_registrar_iana_id LowCardinality(String) DEFAULT '',
    rdap_nameservers String DEFAULT '',
    rdap_status String DEFAULT '',
    rdap_error LowCardinality(String) DEFAULT '',

    -- Reputation (6)
    tranco_rank Nullable(Int32),
    majestic_rank Nullable(Int32),
    majestic_ref_subnets Nullable(Int32),
    is_malware LowCardinality(String) DEFAULT '',
    is_phishing LowCardinality(String) DEFAULT '',
    is_disposable_email LowCardinality(String) DEFAULT '',

    -- Revenue estimation (4)
    estimated_revenue LowCardinality(String) DEFAULT '',
    estimated_employees LowCardinality(String) DEFAULT '',
    revenue_confidence Nullable(Float32),
    revenue_evidence String DEFAULT ''
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(enriched_at)
ORDER BY (domain, enriched_at)
SETTINGS index_granularity = 8192;

-- Auto-maintained latest state per domain.
-- ReplacingMergeTree keeps newest enriched_at per domain.
-- Query with FINAL for exact dedup, or without for slightly stale but faster reads.
CREATE MATERIALIZED VIEW IF NOT EXISTS ls.domains_current
ENGINE = ReplacingMergeTree(enriched_at)
ORDER BY domain
SETTINGS index_granularity = 8192
AS SELECT
    enriched_at, worker, domain,
    ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains,
    dns_a, dns_aaaa, dns_mx, dns_txt, dns_cname,
    http_status, http_response_time, http_blocked,
    http_content_type, http_tech, http_apps, http_language,
    http_title, http_meta_description, http_pages, http_emails, http_error,
    http_h1, http_body_snippet,
    business_model, industry, classification_confidence,
    http_schema_type, http_og_type,
    bgp_ip, bgp_asn_number, bgp_asn_org, bgp_asn_country, bgp_asn_prefix,
    rdap_domain_created_at, rdap_domain_expires_at, rdap_domain_updated_at,
    rdap_registrar, rdap_registrar_iana_id, rdap_nameservers,
    rdap_status, rdap_error,
    tranco_rank, majestic_rank, majestic_ref_subnets,
    is_malware, is_phishing, is_disposable_email,
    estimated_revenue, estimated_employees, revenue_confidence, revenue_evidence
FROM ls.enrichments;
