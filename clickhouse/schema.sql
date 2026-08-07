-- ═══════════════════════════════════════════════════════════════════════════
-- ListSignal ClickHouse schema — AUTHORITATIVE, generated from production.
--
--   Regenerate:  bash clickhouse/dump_schema.sh > clickhouse/schema.sql
--   Last dumped: 2026-08-07
--   Source:      root@45.63.7.58
--
-- Read docs/pipelines.md for how these fit together. In short:
--
--   PIPELINE 1 (discovery)   enrichments ──MV──> domains_current ──view──> domains_fast
--                            plus the persistent `platforms` registry
--   PIPELINE 2 (enrichment)  biz_contact · biz_career · biz_pricing · biz_news
--                            · biz_enrichment
--   COMPACTED PRODUCT        businesses          (built from both, every 5 min)
--   ANALYTICS                daily_* + their mv_daily_* triggers
--
-- This file DOCUMENTS the live schema; it is not applied on deploy. Pending
-- changes live in clickhouse/migrations/ and are applied during a deploy
-- window, then dumped back here. If a migration listed there is absent from
-- this dump, it has not been applied to production yet.
--
-- Views are dumped too, so `v_business_export` appears here once created.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══ mv_daily_blocked ═══
CREATE MATERIALIZED VIEW ls.mv_daily_blocked TO ls.daily_blocked
(
    `day` Date,
    `vendor` LowCardinality(String),
    `cnt` UInt64
)
AS SELECT
    toDate(enriched_at) AS day,
    http_blocked AS vendor,
    count() AS cnt
FROM ls.domains_history
WHERE http_blocked != ''
GROUP BY
    day,
    vendor
;

-- ═══ mv_daily_country ═══
CREATE MATERIALIZED VIEW ls.mv_daily_country TO ls.daily_country
(
    `day` Date,
    `country` LowCardinality(String),
    `cnt` UInt64
)
AS SELECT
    toDate(enriched_at) AS day,
    inferred_country AS country,
    count() AS cnt
FROM ls.domains_history
WHERE inferred_country != ''
GROUP BY
    day,
    country
;

-- ═══ mv_daily_real_businesses ═══
CREATE MATERIALIZED VIEW ls.mv_daily_real_businesses TO ls.daily_real_businesses
(
    `day` Date,
    `cnt` UInt64
)
AS SELECT
    toDate(enriched_at) AS day,
    count() AS cnt
FROM ls.domains_history
WHERE (dns_mx != '') AND (industry != '')
GROUP BY day
;

-- ═══ mv_daily_stats ═══
CREATE MATERIALIZED VIEW ls.mv_daily_stats TO ls.daily_stats
(
    `day` Date,
    `rows_enriched` UInt64
)
AS SELECT
    toDate(enriched_at) AS day,
    count() AS rows_enriched
FROM ls.domains_history
GROUP BY day
;

-- ═══ mv_daily_tech ═══
CREATE MATERIALIZED VIEW ls.mv_daily_tech TO ls.daily_tech
(
    `day` Date,
    `tech` String,
    `cnt` UInt64
)
AS SELECT
    toDate(enriched_at) AS day,
    arrayJoin(splitByChar('|', http_tech)) AS tech,
    count() AS cnt
FROM ls.domains_history
WHERE http_tech != ''
GROUP BY
    day,
    tech
;

-- ═══ mv_domains_current ═══
CREATE MATERIALIZED VIEW ls.mv_domains_current TO ls.domains_current
(
    `enriched_at` DateTime,
    `worker` LowCardinality(String),
    `domain` String,
    `ctl_tld` LowCardinality(String),
    `ctl_issuer` LowCardinality(String),
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String,
    `dns_a` String,
    `dns_aaaa` String,
    `dns_mx` String,
    `dns_txt` String,
    `dns_cname` String,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` LowCardinality(String),
    `http_content_type` LowCardinality(String),
    `http_tech` String,
    `http_apps` String,
    `http_language` LowCardinality(String),
    `http_title` String,
    `http_meta_description` String,
    `http_pages` String,
    `http_emails` String,
    `http_error` LowCardinality(String),
    `http_h1` String,
    `http_body_snippet` String,
    `business_model` LowCardinality(String),
    `industry` LowCardinality(String),
    `classification_confidence` Nullable(Float32),
    `http_schema_type` LowCardinality(String),
    `http_og_type` LowCardinality(String),
    `bgp_ip` String,
    `bgp_asn_number` LowCardinality(String),
    `bgp_asn_org` LowCardinality(String),
    `bgp_asn_country` LowCardinality(String),
    `bgp_asn_prefix` String,
    `inferred_country` LowCardinality(String),
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` LowCardinality(String),
    `rdap_registrar_iana_id` LowCardinality(String),
    `rdap_nameservers` String,
    `rdap_status` String,
    `rdap_error` LowCardinality(String),
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_malware` LowCardinality(String),
    `is_phishing` LowCardinality(String),
    `is_disposable_email` LowCardinality(String),
    `is_junk` LowCardinality(String),
    `estimated_revenue` LowCardinality(String),
    `estimated_employees` LowCardinality(String),
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String
)
AS SELECT
    enriched_at,
    worker,
    domain,
    ctl_tld,
    ctl_issuer,
    ctl_subdomain_count,
    ctl_subdomains,
    dns_a,
    dns_aaaa,
    dns_mx,
    dns_txt,
    dns_cname,
    http_status,
    http_response_time,
    http_blocked,
    http_content_type,
    http_tech,
    http_apps,
    http_language,
    http_title,
    http_meta_description,
    http_pages,
    http_emails,
    http_error,
    http_h1,
    http_body_snippet,
    business_model,
    industry,
    classification_confidence,
    http_schema_type,
    http_og_type,
    bgp_ip,
    bgp_asn_number,
    bgp_asn_org,
    bgp_asn_country,
    bgp_asn_prefix,
    inferred_country,
    rdap_domain_created_at,
    rdap_domain_expires_at,
    rdap_domain_updated_at,
    rdap_registrar,
    rdap_registrar_iana_id,
    rdap_nameservers,
    rdap_status,
    rdap_error,
    tranco_rank,
    majestic_rank,
    majestic_ref_subnets,
    is_malware,
    is_phishing,
    is_disposable_email,
    is_junk,
    estimated_revenue,
    estimated_employees,
    revenue_confidence,
    revenue_evidence
FROM ls.domains_history
;

-- ═══ bak_nxfix_20260730 ═══
CREATE TABLE ls.bak_nxfix_20260730
(
    `src` String,
    `domain` String,
    `enriched_at` DateTime,
    `worker` LowCardinality(String),
    `http_error` LowCardinality(String)
)
ENGINE = MergeTree
ORDER BY (src, domain, enriched_at)
SETTINGS index_granularity = 8192
;

-- ═══ biz_enrichment_log ═══
CREATE TABLE ls.biz_enrichment_log
(
    `domain` String,
    `enriched_at` DateTime,
    `render_engine` LowCardinality(String),
    `product_count` Nullable(UInt32),
    `price_min` Nullable(Float32),
    `price_avg` Nullable(Float32),
    `price_max` Nullable(Float32),
    `new_products_30d` Nullable(UInt32),
    `last_product_at` Nullable(DateTime),
    `oos_ratio` Nullable(Float32),
    `discount_depth` Nullable(Float32),
    `vendor_count` Nullable(UInt32),
    `catalog_age_days` Nullable(UInt32),
    `product_types` String,
    `job_count` Nullable(UInt16),
    `ats_platform` LowCardinality(String),
    `job_departments` String,
    `job_locations` String,
    `seo_score` Nullable(UInt8),
    `seo_issues` String,
    `seo_word_count` Nullable(UInt32),
    `seo_alt_ratio` Nullable(Float32),
    `perf_lcp_ms` Nullable(UInt32),
    `perf_cls` Nullable(Float32),
    `perf_ttfb_ms` Nullable(UInt32),
    `about_text` String,
    `mission` String,
    `hq_location` String,
    `job_locations_top` String,
    `positions_overview` String
)
ENGINE = MergeTree
ORDER BY (domain, enriched_at)
TTL enriched_at + toIntervalDay(365)
SETTINGS index_granularity = 8192
;

-- ═══ domains_history ═══
CREATE TABLE ls.domains_history
(
    `enriched_at` DateTime DEFAULT now(),
    `worker` LowCardinality(String) DEFAULT '',
    `domain` String,
    `ctl_tld` LowCardinality(String) DEFAULT '',
    `ctl_issuer` LowCardinality(String) DEFAULT '',
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String DEFAULT '',
    `dns_a` String DEFAULT '',
    `dns_aaaa` String DEFAULT '',
    `dns_mx` String DEFAULT '',
    `dns_txt` String DEFAULT '',
    `dns_cname` String DEFAULT '',
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` LowCardinality(String) DEFAULT '',
    `http_content_type` LowCardinality(String) DEFAULT '',
    `http_tech` String DEFAULT '',
    `http_apps` String DEFAULT '',
    `http_language` LowCardinality(String) DEFAULT '',
    `http_title` String DEFAULT '',
    `http_meta_description` String DEFAULT '',
    `http_pages` String DEFAULT '',
    `http_emails` String DEFAULT '',
    `http_error` LowCardinality(String) DEFAULT '',
    `http_h1` String DEFAULT '',
    `http_body_snippet` String DEFAULT '',
    `business_model` LowCardinality(String) DEFAULT '',
    `industry` LowCardinality(String) DEFAULT '',
    `classification_confidence` Nullable(Float32),
    `http_schema_type` LowCardinality(String) DEFAULT '',
    `http_og_type` LowCardinality(String) DEFAULT '',
    `bgp_ip` String DEFAULT '',
    `bgp_asn_number` LowCardinality(String) DEFAULT '',
    `bgp_asn_org` LowCardinality(String) DEFAULT '',
    `bgp_asn_country` LowCardinality(String) DEFAULT '',
    `bgp_asn_prefix` String DEFAULT '',
    `inferred_country` LowCardinality(String) DEFAULT '',
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` LowCardinality(String) DEFAULT '',
    `rdap_registrar_iana_id` LowCardinality(String) DEFAULT '',
    `rdap_nameservers` String DEFAULT '',
    `rdap_status` String DEFAULT '',
    `rdap_error` LowCardinality(String) DEFAULT '',
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_malware` LowCardinality(String) DEFAULT '',
    `is_phishing` LowCardinality(String) DEFAULT '',
    `is_disposable_email` LowCardinality(String) DEFAULT '',
    `is_junk` LowCardinality(String) DEFAULT '',
    `estimated_revenue` LowCardinality(String) DEFAULT '',
    `estimated_employees` LowCardinality(String) DEFAULT '',
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String DEFAULT ''
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(enriched_at)
ORDER BY (domain, enriched_at)
TTL enriched_at + toIntervalDay(365)
SETTINGS index_granularity = 8192
;

-- ═══ biz_career ═══
CREATE TABLE ls.biz_career
(
    `domain` String,
    `job_id` UInt64,
    `title` String,
    `location` String,
    `url` String,
    `posted_at` String,
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, job_id)
SETTINGS index_granularity = 8192
;

-- ═══ biz_collections ═══
CREATE TABLE ls.biz_collections
(
    `domain` String,
    `collection_id` UInt64,
    `title` String,
    `handle` String,
    `products_count` UInt32,
    `updated_at` Nullable(DateTime),
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, collection_id)
SETTINGS index_granularity = 8192
;

-- ═══ biz_contact ═══
CREATE TABLE ls.biz_contact
(
    `domain` String,
    `email` String,
    `source_page` LowCardinality(String),
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, email)
SETTINGS index_granularity = 8192
;

-- ═══ biz_enrichment ═══
CREATE TABLE ls.biz_enrichment
(
    `domain` String,
    `enriched_at` DateTime,
    `render_engine` LowCardinality(String),
    `product_count` Nullable(UInt32),
    `price_min` Nullable(Float32),
    `price_avg` Nullable(Float32),
    `price_max` Nullable(Float32),
    `new_products_30d` Nullable(UInt32),
    `last_product_at` Nullable(DateTime),
    `oos_ratio` Nullable(Float32),
    `discount_depth` Nullable(Float32),
    `vendor_count` Nullable(UInt32),
    `catalog_age_days` Nullable(UInt32),
    `product_types` String,
    `job_count` Nullable(UInt16),
    `ats_platform` LowCardinality(String),
    `job_departments` String,
    `job_locations` String,
    `seo_score` Nullable(UInt8),
    `seo_issues` String,
    `seo_word_count` Nullable(UInt32),
    `seo_alt_ratio` Nullable(Float32),
    `perf_lcp_ms` Nullable(UInt32),
    `perf_cls` Nullable(Float32),
    `perf_ttfb_ms` Nullable(UInt32),
    `about_text` String,
    `mission` String,
    `hq_location` String,
    `job_locations_top` String,
    `positions_overview` String
)
ENGINE = ReplacingMergeTree(enriched_at)
ORDER BY domain
SETTINGS index_granularity = 8192
;

-- ═══ biz_news ═══
CREATE TABLE ls.biz_news
(
    `domain` String,
    `news_id` UInt64,
    `title` String,
    `url` String,
    `source` LowCardinality(String),
    `category` LowCardinality(String),
    `amount_usd` Nullable(UInt64),
    `published_at` String,
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, news_id)
SETTINGS index_granularity = 8192
;

-- ═══ biz_pricing ═══
CREATE TABLE ls.biz_pricing
(
    `domain` String,
    `price` Float32,
    `currency` LowCardinality(String),
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, currency, price)
SETTINGS index_granularity = 8192
;

-- ═══ biz_products ═══
CREATE TABLE ls.biz_products
(
    `domain` String,
    `product_id` UInt64,
    `title` String,
    `handle` String,
    `vendor` String,
    `product_type` String,
    `price` Nullable(Float32),
    `available` UInt8,
    `variant_count` UInt16,
    `image_count` UInt16,
    `created_at` Nullable(DateTime),
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, product_id)
SETTINGS index_granularity = 8192
;

-- ═══ businesses ═══
CREATE TABLE ls.businesses
(
    `domain` String,
    `first_seen` DateTime,
    `as_of` DateTime,
    `last_verified_at` DateTime,
    `last_worker` String,
    `crawlable` Nullable(UInt8),
    `last_http_status` Nullable(Int32),
    `last_http_error` String,
    `last_http_blocked` String,
    `dns_alive` UInt8,
    `ctl_tld` String,
    `ctl_issuer` String,
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String,
    `dns_a` String,
    `dns_aaaa` String,
    `dns_mx` String,
    `dns_txt` String,
    `dns_cname` String,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` String,
    `http_content_type` String,
    `http_tech` String,
    `http_apps` String,
    `http_language` String,
    `http_title` String,
    `http_meta_description` String,
    `http_pages` String,
    `http_emails` String,
    `http_h1` String,
    `business_model` String,
    `industry` String,
    `classification_confidence` Nullable(Float32),
    `http_schema_type` String,
    `http_og_type` String,
    `bgp_ip` String,
    `bgp_asn_number` String,
    `bgp_asn_org` String,
    `bgp_asn_country` String,
    `bgp_asn_prefix` String,
    `inferred_country` String,
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` String,
    `rdap_registrar_iana_id` String,
    `rdap_nameservers` String,
    `rdap_status` String,
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_disposable_email` String,
    `is_junk` LowCardinality(String) DEFAULT '',
    `estimated_revenue` String,
    `estimated_employees` String,
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String,
    `product_count` Nullable(UInt32),
    `price_min` Nullable(Float32),
    `price_avg` Nullable(Float32),
    `price_max` Nullable(Float32),
    `new_products_30d` Nullable(UInt32),
    `last_product_at` Nullable(DateTime),
    `oos_ratio` Nullable(Float32),
    `discount_depth` Nullable(Float32),
    `vendor_count` Nullable(UInt32),
    `catalog_age_days` Nullable(UInt32),
    `product_types` String,
    `job_count` Nullable(UInt16),
    `ats_platform` LowCardinality(String),
    `job_departments` String,
    `job_locations` String,
    `seo_score` Nullable(UInt8),
    `seo_issues` String,
    `seo_word_count` Nullable(UInt32),
    `seo_alt_ratio` Nullable(Float32),
    `perf_lcp_ms` Nullable(UInt32),
    `perf_cls` Nullable(Float32),
    `perf_ttfb_ms` Nullable(UInt32),
    `render_engine` LowCardinality(String),
    `depth_enriched_at` Nullable(DateTime),
    `pricing_points` Nullable(UInt8),
    `about_text` String,
    `mission` String,
    `hq_location` String,
    `job_locations_top` String,
    `positions_overview` String,
    `news_count` Nullable(UInt16),
    `last_funding_usd` Nullable(UInt64),
    INDEX idx_product_count product_count TYPE minmax GRANULARITY 4,
    INDEX idx_job_count job_count TYPE minmax GRANULARITY 4,
    INDEX idx_seo_score seo_score TYPE minmax GRANULARITY 4
)
ENGINE = ReplacingMergeTree(as_of)
ORDER BY domain
SETTINGS index_granularity = 8192
;

-- ═══ domains_current ═══
CREATE TABLE ls.domains_current
(
    `enriched_at` DateTime,
    `worker` LowCardinality(String),
    `domain` String,
    `ctl_tld` LowCardinality(String),
    `ctl_issuer` LowCardinality(String),
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String,
    `dns_a` String,
    `dns_aaaa` String,
    `dns_mx` String,
    `dns_txt` String,
    `dns_cname` String,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` LowCardinality(String),
    `http_content_type` LowCardinality(String),
    `http_tech` String,
    `http_apps` String,
    `http_language` LowCardinality(String),
    `http_title` String,
    `http_meta_description` String,
    `http_pages` String,
    `http_emails` String,
    `http_error` LowCardinality(String),
    `http_h1` String,
    `http_body_snippet` String,
    `business_model` LowCardinality(String),
    `industry` LowCardinality(String),
    `classification_confidence` Nullable(Float32),
    `http_schema_type` LowCardinality(String),
    `http_og_type` LowCardinality(String),
    `bgp_ip` String,
    `bgp_asn_number` LowCardinality(String),
    `bgp_asn_org` LowCardinality(String),
    `bgp_asn_country` LowCardinality(String),
    `bgp_asn_prefix` String,
    `inferred_country` LowCardinality(String),
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` LowCardinality(String),
    `rdap_registrar_iana_id` LowCardinality(String),
    `rdap_nameservers` String,
    `rdap_status` String,
    `rdap_error` LowCardinality(String),
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_malware` LowCardinality(String),
    `is_phishing` LowCardinality(String),
    `is_disposable_email` LowCardinality(String),
    `is_junk` LowCardinality(String) DEFAULT '',
    `estimated_revenue` LowCardinality(String),
    `estimated_employees` LowCardinality(String),
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String,
    `country` LowCardinality(String) MATERIALIZED multiIf(inferred_country != '', inferred_country, multiIf(transform(lower(ctl_tld), ['net.uk', 'gov.za', 'com.sg', 'ac.za', 'com.tr', 'co.il', 'co.jp', 'org.za', 'com.au', 'com.my', 'com.mx', 'com.co', 'net.au', 'net.nz', 'edu.cn', 'com.ua', 'co.zw', 'com.hk', 'co.au', 'co.id', 'gov.au', 'org.uk', 'com.sa', 'com.ng', 'co.uk', 'com.cn', 'co.za', 'net.br', 'com.ph', 'gov.uk', 'co.th', 'co.in', 'co.ke', 'com.eg', 'co.kr', 'edu.au', 'net.cn', 'com.gh', 'net.za', 'org.cn', 'ac.uk', 'com.ar', 'org.nz', 'com.ve', 'com.br', 'ac.nz', 'org.au', 'com.pk', 'com.pe', 'com.tw', 'co.nz', 'co.tz'], ['GB', 'ZA', 'SG', 'ZA', 'TR', 'IL', 'JP', 'ZA', 'AU', 'MY', 'MX', 'CO', 'AU', 'NZ', 'CN', 'UA', 'ZW', 'HK', 'AU', 'ID', 'AU', 'GB', 'SA', 'NG', 'GB', 'CN', 'ZA', 'BR', 'PH', 'GB', 'TH', 'IN', 'KE', 'EG', 'KR', 'AU', 'CN', 'GH', 'ZA', 'CN', 'GB', 'AR', 'NZ', 'VE', 'BR', 'NZ', 'AU', 'PK', 'PE', 'TW', 'NZ', 'TZ'], '') != '', transform(lower(ctl_tld), ['net.uk', 'gov.za', 'com.sg', 'ac.za', 'com.tr', 'co.il', 'co.jp', 'org.za', 'com.au', 'com.my', 'com.mx', 'com.co', 'net.au', 'net.nz', 'edu.cn', 'com.ua', 'co.zw', 'com.hk', 'co.au', 'co.id', 'gov.au', 'org.uk', 'com.sa', 'com.ng', 'co.uk', 'com.cn', 'co.za', 'net.br', 'com.ph', 'gov.uk', 'co.th', 'co.in', 'co.ke', 'com.eg', 'co.kr', 'edu.au', 'net.cn', 'com.gh', 'net.za', 'org.cn', 'ac.uk', 'com.ar', 'org.nz', 'com.ve', 'com.br', 'ac.nz', 'org.au', 'com.pk', 'com.pe', 'com.tw', 'co.nz', 'co.tz'], ['GB', 'ZA', 'SG', 'ZA', 'TR', 'IL', 'JP', 'ZA', 'AU', 'MY', 'MX', 'CO', 'AU', 'NZ', 'CN', 'UA', 'ZW', 'HK', 'AU', 'ID', 'AU', 'GB', 'SA', 'NG', 'GB', 'CN', 'ZA', 'BR', 'PH', 'GB', 'TH', 'IN', 'KE', 'EG', 'KR', 'AU', 'CN', 'GH', 'ZA', 'CN', 'GB', 'AR', 'NZ', 'VE', 'BR', 'NZ', 'AU', 'PK', 'PE', 'TW', 'NZ', 'TZ'], ''), transform(lower(ctl_tld), ['is', 'ec', 'cn', 'th', 'bd', 'hk', 'ar', 'fi', 'ee', 'gr', 'eu', 'zw', 'sa', 'mn', 'tz', 'be', 'kh', 'mt', 'fr', 'eg', 'pl', 'de', 'np', 'hn', 'ch', 'se', 've', 'mm', 'sk', 'bo', 'us', 'cy', 'au', 'si', 'it', 'vn', 'pa', 'hr', 'ro', 'mx', 'ie', 'id', 'es', 'lk', 'sg', 'ru', 'cl', 'hu', 'kr', 'gt', 'ae', 'gh', 'ke', 'jp', 'lv', 'no', 'cz', 'ca', 'ph', 'br', 'pk', 'in', 'tw', 'py', 'cr', 'nz', 'dk', 'my', 'nl', 'lu', 'ba', 'za', 'uk', 'lt', 'pe', 'bg', 'rs', 'ua', 'tr', 'uy', 'at', 'il', 'ng', 'pt'], ['IS', 'EC', 'CN', 'TH', 'BD', 'HK', 'AR', 'FI', 'EE', 'GR', 'EU', 'ZW', 'SA', 'MN', 'TZ', 'BE', 'KH', 'MT', 'FR', 'EG', 'PL', 'DE', 'NP', 'HN', 'CH', 'SE', 'VE', 'MM', 'SK', 'BO', 'US', 'CY', 'AU', 'SI', 'IT', 'VN', 'PA', 'HR', 'RO', 'MX', 'IE', 'ID', 'ES', 'LK', 'SG', 'RU', 'CL', 'HU', 'KR', 'GT', 'AE', 'GH', 'KE', 'JP', 'LV', 'NO', 'CZ', 'CA', 'PH', 'BR', 'PK', 'IN', 'TW', 'PY', 'CR', 'NZ', 'DK', 'MY', 'NL', 'LU', 'BA', 'ZA', 'GB', 'LT', 'PE', 'BG', 'RS', 'UA', 'TR', 'UY', 'AT', 'IL', 'NG', 'PT'], '') != '', transform(lower(ctl_tld), ['is', 'ec', 'cn', 'th', 'bd', 'hk', 'ar', 'fi', 'ee', 'gr', 'eu', 'zw', 'sa', 'mn', 'tz', 'be', 'kh', 'mt', 'fr', 'eg', 'pl', 'de', 'np', 'hn', 'ch', 'se', 've', 'mm', 'sk', 'bo', 'us', 'cy', 'au', 'si', 'it', 'vn', 'pa', 'hr', 'ro', 'mx', 'ie', 'id', 'es', 'lk', 'sg', 'ru', 'cl', 'hu', 'kr', 'gt', 'ae', 'gh', 'ke', 'jp', 'lv', 'no', 'cz', 'ca', 'ph', 'br', 'pk', 'in', 'tw', 'py', 'cr', 'nz', 'dk', 'my', 'nl', 'lu', 'ba', 'za', 'uk', 'lt', 'pe', 'bg', 'rs', 'ua', 'tr', 'uy', 'at', 'il', 'ng', 'pt'], ['IS', 'EC', 'CN', 'TH', 'BD', 'HK', 'AR', 'FI', 'EE', 'GR', 'EU', 'ZW', 'SA', 'MN', 'TZ', 'BE', 'KH', 'MT', 'FR', 'EG', 'PL', 'DE', 'NP', 'HN', 'CH', 'SE', 'VE', 'MM', 'SK', 'BO', 'US', 'CY', 'AU', 'SI', 'IT', 'VN', 'PA', 'HR', 'RO', 'MX', 'IE', 'ID', 'ES', 'LK', 'SG', 'RU', 'CL', 'HU', 'KR', 'GT', 'AE', 'GH', 'KE', 'JP', 'LV', 'NO', 'CZ', 'CA', 'PH', 'BR', 'PK', 'IN', 'TW', 'PY', 'CR', 'NZ', 'DK', 'MY', 'NL', 'LU', 'BA', 'ZA', 'GB', 'LT', 'PE', 'BG', 'RS', 'UA', 'TR', 'UY', 'AT', 'IL', 'NG', 'PT'], ''), transform(splitByChar('-', lower(http_language))[1], ['sv', 'te', 'zh', 'th', 'ar', 'fi', 'bn', 'ta', 'ms', 'fr', 'pl', 'sco', 'de', 'he', 'hi', 'it', 'ko', 'ro', 'id', 'es', 'cs', 'ru', 'hu', 'vi', 'no', 'da', 'el', 'nl', 'uk', 'bg', 'tr', 'ja', 'pt'], ['SE', 'IN', 'CN', 'TH', 'SA', 'FI', 'BD', 'IN', 'MY', 'FR', 'PL', 'GB', 'DE', 'IL', 'IN', 'IT', 'KR', 'RO', 'ID', 'ES', 'CZ', 'RU', 'HU', 'VN', 'NO', 'DK', 'GR', 'NL', 'UA', 'BG', 'TR', 'JP', 'BR'], '') != '', transform(splitByChar('-', lower(http_language))[1], ['sv', 'te', 'zh', 'th', 'ar', 'fi', 'bn', 'ta', 'ms', 'fr', 'pl', 'sco', 'de', 'he', 'hi', 'it', 'ko', 'ro', 'id', 'es', 'cs', 'ru', 'hu', 'vi', 'no', 'da', 'el', 'nl', 'uk', 'bg', 'tr', 'ja', 'pt'], ['SE', 'IN', 'CN', 'TH', 'SA', 'FI', 'BD', 'IN', 'MY', 'FR', 'PL', 'GB', 'DE', 'IL', 'IN', 'IT', 'KR', 'RO', 'ID', 'ES', 'CZ', 'RU', 'HU', 'VN', 'NO', 'DK', 'GR', 'NL', 'UA', 'BG', 'TR', 'JP', 'BR'], ''), ((positionCaseInsensitive(bgp_asn_org, 'cloudflare') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'fastly') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'akamai') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'shopify') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'squarespace') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'amazon') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'google') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'microsoft') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'wix') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'netlify') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'vercel') > 0) OR (positionCaseInsensitive(bgp_asn_org, 'automattic') > 0)), '', length(bgp_asn_country) = 2, upper(bgp_asn_country), '')),
    `is_shopify` UInt8 MATERIALIZED http_tech LIKE '%Shopify%'
)
ENGINE = ReplacingMergeTree(enriched_at)
ORDER BY domain
SETTINGS index_granularity = 8192
;

-- ═══ platforms ═══
CREATE TABLE ls.platforms
(
    `domain` String,
    `platform_name` String,
    `category` LowCardinality(String),
    `detection_reason` LowCardinality(String),
    `cert_count` UInt64,
    `cert_rate_per_hour` Float32,
    `max_subdomain_count` UInt32,
    `estimated_hosted_domains` UInt64,
    `first_detected` DateTime,
    `last_seen` DateTime,
    `source` LowCardinality(String) DEFAULT 'auto'
)
ENGINE = ReplacingMergeTree(last_seen)
ORDER BY domain
SETTINGS index_granularity = 8192
;

-- ═══ daily_blocked ═══
CREATE TABLE ls.daily_blocked
(
    `day` Date,
    `vendor` LowCardinality(String),
    `cnt` UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, vendor)
SETTINGS index_granularity = 8192
;

-- ═══ daily_country ═══
CREATE TABLE ls.daily_country
(
    `day` Date,
    `country` LowCardinality(String),
    `cnt` UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, country)
SETTINGS index_granularity = 8192
;

-- ═══ daily_real_businesses ═══
CREATE TABLE ls.daily_real_businesses
(
    `day` Date,
    `cnt` UInt64
)
ENGINE = SummingMergeTree
ORDER BY day
SETTINGS index_granularity = 8192
;

-- ═══ daily_stats ═══
CREATE TABLE ls.daily_stats
(
    `day` Date,
    `rows_enriched` UInt64
)
ENGINE = SummingMergeTree
ORDER BY day
SETTINGS index_granularity = 8192
;

-- ═══ daily_tech ═══
CREATE TABLE ls.daily_tech
(
    `day` Date,
    `tech` LowCardinality(String),
    `cnt` UInt64
)
ENGINE = SummingMergeTree
ORDER BY (day, tech)
SETTINGS index_granularity = 8192
;

-- ═══ domains_fast ═══
CREATE VIEW ls.domains_fast
(
    `enriched_at` DateTime,
    `worker` LowCardinality(String),
    `domain` String,
    `ctl_tld` LowCardinality(String),
    `ctl_issuer` LowCardinality(String),
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String,
    `dns_a` String,
    `dns_aaaa` String,
    `dns_mx` String,
    `dns_txt` String,
    `dns_cname` String,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` LowCardinality(String),
    `http_content_type` LowCardinality(String),
    `http_tech` String,
    `http_apps` String,
    `http_language` LowCardinality(String),
    `http_title` String,
    `http_meta_description` String,
    `http_pages` String,
    `http_emails` String,
    `http_error` LowCardinality(String),
    `http_h1` String,
    `http_body_snippet` String,
    `business_model` LowCardinality(String),
    `industry` LowCardinality(String),
    `classification_confidence` Nullable(Float32),
    `http_schema_type` LowCardinality(String),
    `http_og_type` LowCardinality(String),
    `bgp_ip` String,
    `bgp_asn_number` LowCardinality(String),
    `bgp_asn_org` LowCardinality(String),
    `bgp_asn_country` LowCardinality(String),
    `bgp_asn_prefix` String,
    `inferred_country` LowCardinality(String),
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` LowCardinality(String),
    `rdap_registrar_iana_id` LowCardinality(String),
    `rdap_nameservers` String,
    `rdap_status` String,
    `rdap_error` LowCardinality(String),
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_malware` LowCardinality(String),
    `is_phishing` LowCardinality(String),
    `is_disposable_email` LowCardinality(String),
    `estimated_revenue` LowCardinality(String),
    `estimated_employees` LowCardinality(String),
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String,
    `country` LowCardinality(String),
    `is_shopify` UInt8
)
AS SELECT
    *,
    country,
    is_shopify
FROM ls.domains_current
;

-- ═══ enrichments ═══
CREATE VIEW ls.enrichments
(
    `enriched_at` DateTime,
    `worker` LowCardinality(String),
    `domain` String,
    `ctl_tld` LowCardinality(String),
    `ctl_issuer` LowCardinality(String),
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String,
    `dns_a` String,
    `dns_aaaa` String,
    `dns_mx` String,
    `dns_txt` String,
    `dns_cname` String,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` LowCardinality(String),
    `http_content_type` LowCardinality(String),
    `http_tech` String,
    `http_apps` String,
    `http_language` LowCardinality(String),
    `http_title` String,
    `http_meta_description` String,
    `http_pages` String,
    `http_emails` String,
    `http_error` LowCardinality(String),
    `http_h1` String,
    `http_body_snippet` String,
    `business_model` LowCardinality(String),
    `industry` LowCardinality(String),
    `classification_confidence` Nullable(Float32),
    `http_schema_type` LowCardinality(String),
    `http_og_type` LowCardinality(String),
    `bgp_ip` String,
    `bgp_asn_number` LowCardinality(String),
    `bgp_asn_org` LowCardinality(String),
    `bgp_asn_country` LowCardinality(String),
    `bgp_asn_prefix` String,
    `inferred_country` LowCardinality(String),
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` LowCardinality(String),
    `rdap_registrar_iana_id` LowCardinality(String),
    `rdap_nameservers` String,
    `rdap_status` String,
    `rdap_error` LowCardinality(String),
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_malware` LowCardinality(String),
    `is_phishing` LowCardinality(String),
    `is_disposable_email` LowCardinality(String),
    `estimated_revenue` LowCardinality(String),
    `estimated_employees` LowCardinality(String),
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String
)
AS SELECT *
FROM ls.domains_history
;

-- ═══ v_business_export ═══
CREATE VIEW ls.v_business_export
(
    `domain` String,
    `title` String,
    `model` String,
    `industry` String,
    `platform` String,
    `country` String,
    `language` String,
    `all_emails` String,
    `email_count` UInt64,
    `has_mail` UInt8,
    `tech` String,
    `apps` String,
    `dns_a` String,
    `dns_mx` String,
    `dns_cname` String,
    `dns_txt` String,
    `hosting` String,
    `hosting_country` String,
    `bgp_ip` String,
    `registrar` String,
    `domain_created` Nullable(DateTime),
    `domain_age_days` Nullable(Int64),
    `nameservers` String,
    `ssl_issuer` String,
    `subdomains` Nullable(Int32),
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `ref_subnets` Nullable(Int32),
    `revenue` String,
    `employees` String,
    `revenue_confidence` Nullable(Float32),
    `revenue_why` String,
    `products` Nullable(UInt32),
    `product_price_min` Nullable(Float32),
    `product_price_avg` Nullable(Float32),
    `product_price_max` Nullable(Float32),
    `new_products_30d` Nullable(UInt32),
    `vendors` Nullable(UInt32),
    `oos_ratio` Nullable(Float32),
    `discount_depth` Nullable(Float32),
    `catalog_age_days` Nullable(UInt32),
    `product_types` String,
    `top_products` String,
    `products_stored` UInt64,
    `collections` String,
    `collections_count` UInt64,
    `pricing_observed` String,
    `pricing_low` Float32,
    `pricing_high` Float32,
    `pricing_currency` String,
    `pricing_points` Nullable(UInt8),
    `job_count` Nullable(UInt16),
    `ats` LowCardinality(String),
    `job_departments` String,
    `job_locations` String,
    `job_titles` String,
    `mission` String,
    `hq_location` String,
    `positions_overview` String,
    `about_text` String,
    `news_titles` String,
    `news_count` Nullable(UInt16),
    `last_funding_usd` Nullable(UInt64),
    `seo_score` Nullable(UInt8),
    `seo_issues` String,
    `seo_word_count` Nullable(UInt32),
    `seo_alt_ratio` Nullable(Float32),
    `perf_lcp_ms` Nullable(UInt32),
    `perf_cls` Nullable(Float32),
    `perf_ttfb_ms` Nullable(UInt32),
    `crawlable` Nullable(UInt8),
    `dns_alive` UInt8,
    `last_http_status` Nullable(Int32),
    `last_http_error` String,
    `last_http_blocked` String,
    `render_engine` LowCardinality(String),
    `first_seen` DateTime,
    `last_verified_at` DateTime,
    `depth_enriched_at` Nullable(DateTime)
)
AS SELECT
    b.domain AS domain,
    b.http_title AS title,
    b.business_model AS model,
    b.industry,
    multiIf((b.product_count > 0) OR (positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'shopify') > 0), 'Shopify', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'woocommerce') > 0, 'WooCommerce', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'bigcommerce') > 0, 'BigCommerce', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'magento') > 0, 'Magento', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'squarespace') > 0, 'Squarespace', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'webflow') > 0, 'Webflow', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'wix') > 0, 'Wix', positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'wordpress') > 0, 'WordPress', '') AS platform,
    b.inferred_country AS country,
    b.http_language AS language,
    arrayStringConcat(arrayFilter(x -> (x != ''), [b.http_emails, c.emails]), '|') AS all_emails,
    c.email_count,
    b.dns_mx != '' AS has_mail,
    b.http_tech AS tech,
    b.http_apps AS apps,
    b.dns_a,
    b.dns_mx,
    b.dns_cname,
    b.dns_txt,
    b.bgp_asn_org AS hosting,
    b.bgp_asn_country AS hosting_country,
    b.bgp_ip,
    b.rdap_registrar AS registrar,
    b.rdap_domain_created_at AS domain_created,
    dateDiff('day', b.rdap_domain_created_at, now()) AS domain_age_days,
    b.rdap_nameservers AS nameservers,
    b.ctl_issuer AS ssl_issuer,
    b.ctl_subdomain_count AS subdomains,
    b.tranco_rank,
    b.majestic_rank,
    b.majestic_ref_subnets AS ref_subnets,
    b.estimated_revenue AS revenue,
    b.estimated_employees AS employees,
    b.revenue_confidence,
    b.revenue_evidence AS revenue_why,
    b.product_count AS products,
    b.price_min AS product_price_min,
    b.price_avg AS product_price_avg,
    b.price_max AS product_price_max,
    b.new_products_30d,
    b.vendor_count AS vendors,
    b.oos_ratio,
    b.discount_depth,
    b.catalog_age_days,
    b.product_types,
    pr.top_products AS top_products,
    pr.stored_products AS products_stored,
    col.collection_names AS collections,
    col.collection_count AS collections_count,
    p.price_list AS pricing_observed,
    p.price_low AS pricing_low,
    p.price_high AS pricing_high,
    p.currency AS pricing_currency,
    b.pricing_points,
    b.job_count,
    b.ats_platform AS ats,
    b.job_departments,
    b.job_locations,
    j.job_titles,
    b.mission,
    b.hq_location,
    b.positions_overview,
    b.about_text,
    n.news_titles,
    b.news_count,
    b.last_funding_usd,
    b.seo_score,
    b.seo_issues,
    b.seo_word_count,
    b.seo_alt_ratio,
    b.perf_lcp_ms,
    b.perf_cls,
    b.perf_ttfb_ms,
    b.crawlable,
    b.dns_alive,
    b.last_http_status,
    b.last_http_error,
    b.last_http_blocked,
    b.render_engine,
    b.first_seen,
    b.last_verified_at,
    b.depth_enriched_at
FROM ls.businesses AS b
FINAL
LEFT JOIN
(
    SELECT
        domain,
        arrayStringConcat(groupArray(email), '|') AS emails,
        count() AS email_count
    FROM ls.biz_contact
    FINAL
    GROUP BY domain
) AS c ON b.domain = c.domain
LEFT JOIN
(
    SELECT
        domain,
        arrayStringConcat(arrayMap(x -> toString(x), arraySort(groupArray(price))), '|') AS price_list,
        min(price) AS price_low,
        max(price) AS price_high,
        any(currency) AS currency
    FROM ls.biz_pricing
    FINAL
    GROUP BY domain
) AS p ON b.domain = p.domain
LEFT JOIN
(
    SELECT
        domain,
        arrayStringConcat(groupArray(title), '|') AS job_titles
    FROM ls.biz_career
    FINAL
    GROUP BY domain
) AS j ON b.domain = j.domain
LEFT JOIN
(
    SELECT
        domain,
        arrayStringConcat(groupArray(title), '|') AS news_titles
    FROM ls.biz_news
    FINAL
    GROUP BY domain
) AS n ON b.domain = n.domain
LEFT JOIN
(
    SELECT
        domain,
        arrayStringConcat(arraySlice(groupArray(title), 1, 15), '|') AS top_products,
        count() AS stored_products
    FROM ls.biz_products
    FINAL
    GROUP BY domain
) AS pr ON b.domain = pr.domain
LEFT JOIN
(
    SELECT
        domain,
        arrayStringConcat(arraySlice(groupArray(title), 1, 25), '|') AS collection_names,
        count() AS collection_count
    FROM ls.biz_collections
    FINAL
    GROUP BY domain
) AS col ON b.domain = col.domain
;

-- ═══ v_business_unified ═══
CREATE VIEW ls.v_business_unified
(
    `domain` String,
    `first_seen` DateTime,
    `as_of` DateTime,
    `last_verified_at` DateTime,
    `last_worker` String,
    `crawlable` Nullable(UInt8),
    `last_http_status` Nullable(Int32),
    `last_http_error` String,
    `last_http_blocked` String,
    `dns_alive` UInt8,
    `ctl_tld` String,
    `ctl_issuer` String,
    `ctl_subdomain_count` Nullable(Int32),
    `ctl_subdomains` String,
    `dns_a` String,
    `dns_aaaa` String,
    `dns_mx` String,
    `dns_txt` String,
    `dns_cname` String,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_blocked` String,
    `http_content_type` String,
    `http_tech` String,
    `http_apps` String,
    `http_language` String,
    `http_title` String,
    `http_meta_description` String,
    `http_pages` String,
    `http_emails` String,
    `http_h1` String,
    `business_model` String,
    `industry` String,
    `classification_confidence` Nullable(Float32),
    `http_schema_type` String,
    `http_og_type` String,
    `bgp_ip` String,
    `bgp_asn_number` String,
    `bgp_asn_org` String,
    `bgp_asn_country` String,
    `bgp_asn_prefix` String,
    `inferred_country` String,
    `rdap_domain_created_at` Nullable(DateTime),
    `rdap_domain_expires_at` Nullable(DateTime),
    `rdap_domain_updated_at` Nullable(DateTime),
    `rdap_registrar` String,
    `rdap_registrar_iana_id` String,
    `rdap_nameservers` String,
    `rdap_status` String,
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `majestic_ref_subnets` Nullable(Int32),
    `is_disposable_email` String,
    `estimated_revenue` String,
    `estimated_employees` String,
    `revenue_confidence` Nullable(Float32),
    `revenue_evidence` String,
    `product_count` Nullable(UInt32),
    `price_min` Nullable(Float32),
    `price_avg` Nullable(Float32),
    `price_max` Nullable(Float32),
    `new_products_30d` Nullable(UInt32),
    `last_product_at` Nullable(DateTime),
    `oos_ratio` Nullable(Float32),
    `discount_depth` Nullable(Float32),
    `vendor_count` Nullable(UInt32),
    `catalog_age_days` Nullable(UInt32),
    `product_types` String,
    `job_count` Nullable(UInt16),
    `ats_platform` LowCardinality(String),
    `job_departments` String,
    `job_locations` String,
    `seo_score` Nullable(UInt8),
    `seo_issues` String,
    `seo_word_count` Nullable(UInt32),
    `seo_alt_ratio` Nullable(Float32),
    `perf_lcp_ms` Nullable(UInt32),
    `perf_cls` Nullable(Float32),
    `perf_ttfb_ms` Nullable(UInt32),
    `render_engine` LowCardinality(String),
    `depth_enriched_at` Nullable(DateTime),
    `pricing_points` Nullable(UInt8),
    `about_text` String,
    `mission` String,
    `hq_location` String,
    `job_locations_top` String,
    `positions_overview` String,
    `news_count` Nullable(UInt16),
    `last_funding_usd` Nullable(UInt64),
    `contact_emails` Array(String),
    `contact_count` UInt64,
    `pricing_observed` Array(Float32),
    `pricing_currencies` Array(String),
    `career_titles` Array(String),
    `career_locations` Array(String),
    `catalog_titles` Array(String),
    `catalog_rows` UInt64,
    `collection_titles` Array(String),
    `news_headlines` Array(String)
)
AS SELECT
    b.domain AS domain,
    b.first_seen AS first_seen,
    b.as_of AS as_of,
    b.last_verified_at AS last_verified_at,
    b.last_worker AS last_worker,
    b.crawlable AS crawlable,
    b.last_http_status AS last_http_status,
    b.last_http_error AS last_http_error,
    b.last_http_blocked AS last_http_blocked,
    b.dns_alive AS dns_alive,
    b.ctl_tld AS ctl_tld,
    b.ctl_issuer AS ctl_issuer,
    b.ctl_subdomain_count AS ctl_subdomain_count,
    b.ctl_subdomains AS ctl_subdomains,
    b.dns_a AS dns_a,
    b.dns_aaaa AS dns_aaaa,
    b.dns_mx AS dns_mx,
    b.dns_txt AS dns_txt,
    b.dns_cname AS dns_cname,
    b.http_status AS http_status,
    b.http_response_time AS http_response_time,
    b.http_blocked AS http_blocked,
    b.http_content_type AS http_content_type,
    b.http_tech AS http_tech,
    b.http_apps AS http_apps,
    b.http_language AS http_language,
    b.http_title AS http_title,
    b.http_meta_description AS http_meta_description,
    b.http_pages AS http_pages,
    b.http_emails AS http_emails,
    b.http_h1 AS http_h1,
    b.business_model AS business_model,
    b.industry AS industry,
    b.classification_confidence AS classification_confidence,
    b.http_schema_type AS http_schema_type,
    b.http_og_type AS http_og_type,
    b.bgp_ip AS bgp_ip,
    b.bgp_asn_number AS bgp_asn_number,
    b.bgp_asn_org AS bgp_asn_org,
    b.bgp_asn_country AS bgp_asn_country,
    b.bgp_asn_prefix AS bgp_asn_prefix,
    b.inferred_country AS inferred_country,
    b.rdap_domain_created_at AS rdap_domain_created_at,
    b.rdap_domain_expires_at AS rdap_domain_expires_at,
    b.rdap_domain_updated_at AS rdap_domain_updated_at,
    b.rdap_registrar AS rdap_registrar,
    b.rdap_registrar_iana_id AS rdap_registrar_iana_id,
    b.rdap_nameservers AS rdap_nameservers,
    b.rdap_status AS rdap_status,
    b.tranco_rank AS tranco_rank,
    b.majestic_rank AS majestic_rank,
    b.majestic_ref_subnets AS majestic_ref_subnets,
    b.is_disposable_email AS is_disposable_email,
    b.estimated_revenue AS estimated_revenue,
    b.estimated_employees AS estimated_employees,
    b.revenue_confidence AS revenue_confidence,
    b.revenue_evidence AS revenue_evidence,
    b.product_count AS product_count,
    b.price_min AS price_min,
    b.price_avg AS price_avg,
    b.price_max AS price_max,
    b.new_products_30d AS new_products_30d,
    b.last_product_at AS last_product_at,
    b.oos_ratio AS oos_ratio,
    b.discount_depth AS discount_depth,
    b.vendor_count AS vendor_count,
    b.catalog_age_days AS catalog_age_days,
    b.product_types AS product_types,
    b.job_count AS job_count,
    b.ats_platform AS ats_platform,
    b.job_departments AS job_departments,
    b.job_locations AS job_locations,
    b.seo_score AS seo_score,
    b.seo_issues AS seo_issues,
    b.seo_word_count AS seo_word_count,
    b.seo_alt_ratio AS seo_alt_ratio,
    b.perf_lcp_ms AS perf_lcp_ms,
    b.perf_cls AS perf_cls,
    b.perf_ttfb_ms AS perf_ttfb_ms,
    b.render_engine AS render_engine,
    b.depth_enriched_at AS depth_enriched_at,
    b.pricing_points AS pricing_points,
    b.about_text AS about_text,
    b.mission AS mission,
    b.hq_location AS hq_location,
    b.job_locations_top AS job_locations_top,
    b.positions_overview AS positions_overview,
    b.news_count AS news_count,
    b.last_funding_usd AS last_funding_usd,
    c.contact_emails,
    c.contact_count,
    p.pricing_observed,
    p.pricing_currencies,
    j.career_titles,
    j.career_locations,
    pr.catalog_titles,
    pr.catalog_rows,
    col.collection_titles,
    n.news_headlines
FROM
(
    SELECT *
    FROM ls.businesses
    FINAL
    WHERE domain IN (
        SELECT domain
        FROM ls.biz_enrichment
    )
) AS b
LEFT JOIN
(
    SELECT
        domain,
        groupArray(email) AS contact_emails,
        count() AS contact_count
    FROM ls.biz_contact
    FINAL
    GROUP BY domain
) AS c ON b.domain = c.domain
LEFT JOIN
(
    SELECT
        domain,
        arraySort(groupArray(price)) AS pricing_observed,
        groupUniqArray(currency) AS pricing_currencies
    FROM ls.biz_pricing
    FINAL
    GROUP BY domain
) AS p ON b.domain = p.domain
LEFT JOIN
(
    SELECT
        domain,
        groupArray(title) AS career_titles,
        groupUniqArray(location) AS career_locations
    FROM ls.biz_career
    FINAL
    GROUP BY domain
) AS j ON b.domain = j.domain
LEFT JOIN
(
    SELECT
        domain,
        arraySlice(groupArray(title), 1, 25) AS catalog_titles,
        count() AS catalog_rows
    FROM ls.biz_products
    FINAL
    GROUP BY domain
) AS pr ON b.domain = pr.domain
LEFT JOIN
(
    SELECT
        domain,
        arraySlice(groupArray(title), 1, 25) AS collection_titles
    FROM ls.biz_collections
    FINAL
    GROUP BY domain
) AS col ON b.domain = col.domain
LEFT JOIN
(
    SELECT
        domain,
        groupArray(title) AS news_headlines
    FROM ls.biz_news
    FINAL
    GROUP BY domain
) AS n ON b.domain = n.domain
;

