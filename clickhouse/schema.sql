-- ============================================================================
-- LISTSIGNAL CLICKHOUSE SCHEMA v2 — DISTRIBUTED PIPELINE
-- ============================================================================
--
-- Architecture:
--   enrichments (append-only log) → domains_current (auto-maintained latest)
--
-- One INSERT point. History and latest state handled automatically.
-- No staging tables. No import scripts. No manual merges.
--
-- Usage:
--   clickhouse client < clickhouse/schema.sql
--
-- Reset:
--   clickhouse client --query "DROP DATABASE IF NOT EXISTS ls"
--   clickhouse client < clickhouse/schema.sql
-- ============================================================================

CREATE DATABASE IF NOT EXISTS ls;

-- ============================================================================
-- ENRICHMENTS: Append-only log of every enrichment result
-- ============================================================================
-- Every worker INSERT goes here. One row per domain per enrichment run.
-- Partitioned by month for easy retention management:
--   ALTER TABLE ls.enrichments DROP PARTITION 202601;
-- ============================================================================

CREATE TABLE IF NOT EXISTS ls.enrichments
(
    -- Metadata
    enriched_at DateTime DEFAULT now(),
    worker LowCardinality(String) DEFAULT '',

    -- Domain identity (from CTL)
    domain String,
    ctl_tld LowCardinality(String) DEFAULT '',
    ctl_issuer LowCardinality(String) DEFAULT '',
    ctl_subdomain_count Nullable(Int32),
    ctl_subdomains String DEFAULT '',
    ctl_web_scoring Nullable(Int32),
    ctl_budget_scoring Nullable(Int32),
    ctl_security_scoring Nullable(Int32),

    -- DNS enrichment
    dns_a String DEFAULT '',
    dns_aaaa String DEFAULT '',
    dns_mx String DEFAULT '',
    dns_txt String DEFAULT '',
    dns_cname String DEFAULT '',
    dns_web_scoring Nullable(Int32),
    dns_email_scoring Nullable(Int32),
    dns_budget_scoring Nullable(Int32),
    dns_security_scoring Nullable(Int32),

    -- HTTP enrichment
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

    -- BGP enrichment
    bgp_ip String DEFAULT '',
    bgp_asn_number LowCardinality(String) DEFAULT '',
    bgp_asn_org LowCardinality(String) DEFAULT '',
    bgp_asn_country LowCardinality(String) DEFAULT '',
    bgp_asn_prefix String DEFAULT '',
    bgp_web_scoring Nullable(Int32),
    bgp_budget_scoring Nullable(Int32)
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(enriched_at)
ORDER BY (domain, enriched_at)
SETTINGS index_granularity = 8192;

-- ============================================================================
-- DOMAINS_CURRENT: Auto-maintained latest state per domain
-- ============================================================================
-- This is a REAL table backed by ReplacingMergeTree.
-- The materialized view acts as an auto-insert trigger from enrichments.
-- Background merges keep only the row with the highest enriched_at per domain.
--
-- Query without FINAL for lead gen (fast, may have rare duplicates).
-- Query with FINAL for single-domain lookups (exact, slightly slower).
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS ls.domains_current
ENGINE = ReplacingMergeTree(enriched_at)
ORDER BY domain
SETTINGS index_granularity = 8192
AS SELECT
    enriched_at,
    worker,
    domain,
    ctl_tld,
    ctl_issuer,
    ctl_subdomain_count,
    ctl_subdomains,
    ctl_web_scoring,
    ctl_budget_scoring,
    ctl_security_scoring,
    dns_a,
    dns_aaaa,
    dns_mx,
    dns_txt,
    dns_cname,
    dns_web_scoring,
    dns_email_scoring,
    dns_budget_scoring,
    dns_security_scoring,
    http_status,
    http_response_time,
    http_server,
    http_cdn,
    http_blocked,
    http_content_type,
    http_tech,
    http_tools,
    http_is_js_site,
    http_title,
    http_meta_description,
    http_pages,
    http_emails,
    http_error,
    bgp_ip,
    bgp_asn_number,
    bgp_asn_org,
    bgp_asn_country,
    bgp_asn_prefix,
    bgp_web_scoring,
    bgp_budget_scoring,
    -- Materialized scoring columns
    ifNull(ctl_web_scoring, 0) + ifNull(dns_web_scoring, 0) + ifNull(bgp_web_scoring, 0) AS total_web_scoring,
    ifNull(ctl_budget_scoring, 0) + ifNull(dns_budget_scoring, 0) + ifNull(bgp_budget_scoring, 0) AS total_budget_scoring,
    ifNull(ctl_security_scoring, 0) + ifNull(dns_security_scoring, 0) AS total_security_scoring
FROM ls.enrichments;

-- ============================================================================
-- SETUP COMPLETE
-- ============================================================================
-- Verify:
--   clickhouse client --database=ls --query "SHOW TABLES"
--   → enrichments, domains_current
--
-- Insert test:
--   INSERT INTO ls.enrichments (domain, ctl_tld) VALUES ('test.com', 'com');
--   SELECT * FROM ls.domains_current WHERE domain = 'test.com';
-- ============================================================================
