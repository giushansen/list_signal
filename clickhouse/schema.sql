-- ═══════════════════════════════════════════════════════════════════════════
-- ListSignal ClickHouse schema — AUTHORITATIVE, generated from production.
--
--   Regenerate:  bash clickhouse/dump_schema.sh > clickhouse/schema.sql
--   Last dumped: 2026-07-29
--
-- Read docs/pipelines.md for how these fit together. In short:
--
--   PIPELINE 1 (discovery)   enrichments ──MV──> domains_current ──view──> domains_fast
--                            (renamed to domains_history by migrate_pipeline2.sh)
--   PIPELINE 2 (enrichment)  biz_contact · biz_career · biz_pricing · biz_news
--                            · biz_enrichment
--   COMPACTED PRODUCT        businesses          (built from both, every 5 min)
--   ANALYTICS               daily_* + their mv_daily_* triggers
--
-- `business_keys` is a scratch table from the one-off businesses backfill and
-- is not part of the running system.
--
-- NOTE: this file DOCUMENTS the live schema; it is not applied on deploy.
-- Changes go through devops/listsignal/clickhouse_pipeline2.sql (additive) and
-- migrate_pipeline2.sh (the rename), then get dumped back here.
-- ═══════════════════════════════════════════════════════════════════════════

-- ═══ domains_current ═══
CREATE MATERIALIZED VIEW ls.domains_current
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
    estimated_revenue,
    estimated_employees,
    revenue_confidence,
    revenue_evidence
FROM ls.enrichments
;

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
FROM ls.enrichments
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
FROM ls.enrichments
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
FROM ls.enrichments
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
FROM ls.enrichments
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
FROM ls.enrichments
WHERE http_tech != ''
GROUP BY
    day,
    tech
;

-- ═══ business_keys ═══
CREATE TABLE ls.business_keys
(
    `domain` String
)
ENGINE = MergeTree
ORDER BY domain
SETTINGS index_granularity = 8192
;

-- ═══ enrichments ═══
CREATE TABLE ls.enrichments
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
FROM ls.`.inner_id.93383d8f-b7a5-4f72-96e0-9468daaefda2`
;

