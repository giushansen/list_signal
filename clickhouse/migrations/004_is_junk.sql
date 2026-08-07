-- 004: is_junk — parked/placeholder detection as a first-class column.
--
-- Why: BusinessClassifier always detected parking pages and default Shopify
-- storefronts, but only *silently* (the row got an empty classification).
-- Parked domains were indistinguishable from real-but-unclassifiable
-- businesses and could be exported to customers as leads. Golden-set work
-- (analysis/golden_set/) needs the junk rate measurable.
--
-- Values: '' (no junk detected — NOT "verified real"), 'parked',
-- 'placeholder'. LowCardinality + mostly-empty ⇒ storage is ~free
-- (see CLAUDE.md ClickHouse facts).
--
-- Applied to prod 2026-08-07. Additive only; safe while old code runs
-- (old rows default to ''). ALTERs are instant (metadata-only).

ALTER TABLE ls.domains_history ADD COLUMN IF NOT EXISTS
  is_junk LowCardinality(String) DEFAULT '' AFTER is_disposable_email;

ALTER TABLE ls.domains_current ADD COLUMN IF NOT EXISTS
  is_junk LowCardinality(String) DEFAULT '' AFTER is_disposable_email;

ALTER TABLE ls.businesses ADD COLUMN IF NOT EXISTS
  is_junk LowCardinality(String) DEFAULT '' AFTER is_disposable_email;

-- mv_domains_current must forward the new column (a TO-table MV only writes
-- what its SELECT names). MODIFY QUERY rewrites the SELECT in place — no
-- DROP/CREATE, no gap in the stream. The full statement lives in prod
-- history; the shape is:
--
--   ALTER TABLE ls.mv_domains_current MODIFY QUERY
--   SELECT <all previous columns>, is_junk, <rest> FROM ls.domains_history;
--
-- (Run SHOW CREATE TABLE ls.mv_domains_current, add is_junk after
--  is_disposable_email in both the column list and the SELECT.)
