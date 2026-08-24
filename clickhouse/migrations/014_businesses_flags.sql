-- businesses: is_shopify / is_saas flags (2026-08-24)
--
-- The dashboard's two most-used segment filters were the two most expensive
-- predicates in the product table, because both were evaluated against wide
-- columns on every one of 14.2M rows (nothing prunes: businesses is ORDER BY
-- domain with no partitioning, and first_seen is scattered — an `aaa*` domain
-- slice spans 82 days — so no skip index can help either).
--
-- Measured on prod under load, before this change:
--   positionCaseInsensitive(http_tech,'Shopify') > 0   38,979ms   688 MB
--   business_model = 'SaaS'                             7,288ms   141 MB
-- http_tech alone is 195 MiB compressed and must be decompressed and
-- substring-searched in full; business_model is 56 MiB of LowCardinality.
-- Two UInt8 flags are ~14 MB each and compare as integers.
--
-- is_shopify uses the SAME expression as domains_current.is_shopify
-- (schema.sql:645) so the landing page, domains_fast and the product table
-- can never disagree about what "Shopify" means.
--
-- MATERIALIZED, not DEFAULT: it is derived, must never be written by a
-- pipeline, and is excluded from SELECT * (which is what broke the enrichment
-- cutover once — see docs/architecture.md).
ALTER TABLE ls.businesses
    ADD COLUMN IF NOT EXISTS `is_shopify` UInt8 MATERIALIZED http_tech LIKE '%Shopify%',
    ADD COLUMN IF NOT EXISTS `is_saas`    UInt8 MATERIALIZED business_model = 'SaaS';

-- Backfill. Without this the flags are still CORRECT (ClickHouse evaluates the
-- expression on the fly for parts written before the column existed) but bring
-- no speed-up at all, because computing them re-reads the very columns we are
-- trying to avoid. The mutation is what turns them into stored bytes.
-- businesses is 5.5 GiB on disk, so this is minutes, not hours.
ALTER TABLE ls.businesses MATERIALIZE COLUMN `is_shopify`;
ALTER TABLE ls.businesses MATERIALIZE COLUMN `is_saas`;
