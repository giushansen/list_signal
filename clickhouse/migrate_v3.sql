-- LISTSIGNAL v2 → v3 MIGRATION (RDAP + Reputation). Safe to run multiple times.
-- Run: clickhouse client < clickhouse/migrate_v3.sql

-- RDAP columns
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_domain_created_at Nullable(DateTime);
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_domain_expires_at Nullable(DateTime);
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_domain_updated_at Nullable(DateTime);
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_registrar LowCardinality(String) DEFAULT '';
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_registrar_iana_id LowCardinality(String) DEFAULT '';
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_nameservers String DEFAULT '';
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_status String DEFAULT '';
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS rdap_error LowCardinality(String) DEFAULT '';

-- Reputation columns
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS tranco_rank Nullable(Int32);
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS majestic_rank Nullable(Int32);
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS majestic_ref_subnets Nullable(Int32);
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS is_malware LowCardinality(String) DEFAULT '';
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS is_phishing LowCardinality(String) DEFAULT '';
ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS is_disposable_email LowCardinality(String) DEFAULT '';

-- Recreate materialized view
DROP VIEW IF EXISTS ls.domains_current;
CREATE MATERIALIZED VIEW IF NOT EXISTS ls.domains_current
ENGINE = ReplacingMergeTree(enriched_at) ORDER BY domain SETTINGS index_granularity = 8192
AS SELECT
    enriched_at, worker, domain,
    ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains,
    dns_a, dns_aaaa, dns_mx, dns_txt, dns_cname,
    http_title, http_meta_description, http_pages, http_emails, http_error,
    bgp_ip, bgp_asn_number, bgp_asn_org, bgp_asn_country, bgp_asn_prefix,
    rdap_domain_created_at, rdap_domain_expires_at, rdap_domain_updated_at,
    rdap_registrar, rdap_registrar_iana_id, rdap_nameservers,
    tranco_rank, majestic_rank, majestic_ref_subnets,
    is_malware, is_phishing, is_disposable_email,
FROM ls.enrichments;
