-- 030 (2026-10-28): one-byte flag for "has a published address" on the
-- product table. The explorer's target ranking, the API's relevance sort
-- and the has_email filter evaluated notEmpty(http_emails) on every row,
-- which decompresses the 243 MB array column: 0.9 s of the 1.5 s the first
-- explorer page's ranking took on the master (4 cores, 27M rows). Declared
-- in LS.Schema.Columns (@materialized) like is_shopify; the compactor never
-- writes it, the table computes it on insert. MATERIALIZE COLUMN fills the
-- existing parts (one narrow column, minutes). Apply on the master before
-- the release that reads it:
--   clickhouse-client -d ls --multiquery < clickhouse/migrations/030_businesses_has_email.sql
ALTER TABLE ls.businesses ADD COLUMN IF NOT EXISTS `has_email` UInt8 MATERIALIZED notEmpty(http_emails);
ALTER TABLE ls.businesses MATERIALIZE COLUMN `has_email`;
