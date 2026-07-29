-- ═══════════════════════════════════════════════════════════════════════════
-- 003 — drop four columns from `businesses` that can never hold data
--
-- STATUS: NOT YET APPLIED TO PRODUCTION.
-- Run AFTER deploying the matching release (the old release still SELECTs
-- these columns when compacting; dropping them first breaks compaction).
--
-- is_malware / is_phishing
--   Structurally always empty. The compactor that builds `businesses` ends with
--       HAVING (is_malware = '' AND is_phishing = '')
--   so a flagged domain is excluded from the table by construction — the column
--   could only ever be ''. Measured on 19,733 rows: 0 non-empty, as predicted.
--   The signal is NOT lost: the flags stay on `domains_history` /
--   `domains_current`, where the filtering decision is actually made, and the
--   Explorer still reads them from there.
--
-- seo_internal_links / seo_external_links
--   A raw count of <a> tags says nothing about SEO quality on its own, nothing
--   filters on it, and it is not part of the published SEO score.
--
-- Metadata-only on a MergeTree: instant, no data rewritten.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE ls.businesses DROP COLUMN IF EXISTS is_malware;
ALTER TABLE ls.businesses DROP COLUMN IF EXISTS is_phishing;
ALTER TABLE ls.businesses DROP COLUMN IF EXISTS seo_internal_links;
ALTER TABLE ls.businesses DROP COLUMN IF EXISTS seo_external_links;

ALTER TABLE ls.biz_enrichment DROP COLUMN IF EXISTS seo_internal_links;
ALTER TABLE ls.biz_enrichment DROP COLUMN IF EXISTS seo_external_links;

-- ROLLBACK: re-add as nullable; the data was empty, so nothing is lost.
--   ALTER TABLE ls.businesses ADD COLUMN is_malware LowCardinality(String) DEFAULT '';
--   ALTER TABLE ls.businesses ADD COLUMN is_phishing LowCardinality(String) DEFAULT '';
--   ALTER TABLE ls.businesses ADD COLUMN seo_internal_links Nullable(UInt32);
--   ALTER TABLE ls.businesses ADD COLUMN seo_external_links Nullable(UInt32);
