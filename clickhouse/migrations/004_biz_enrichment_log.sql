-- ═══════════════════════════════════════════════════════════════════════════
-- 004 — biz_enrichment_log: append-only history of every depth enrichment.
--
-- STATUS: NOT YET APPLIED TO PRODUCTION. Safe on a LIVE app (new table only),
-- but apply BEFORE deploying the release whose writer dual-writes into it —
-- the writer logs an insert error every batch until the table exists.
--
-- WHY
--   biz_enrichment is a ReplacingMergeTree: each re-enrichment supersedes the
--   previous row at merge time, so "how did product_count / job_count /
--   pricing change over months" was unanswerable at the BUSINESS level even
--   though domains_history answers it at the domain level. This log is the
--   depth-side twin of domains_history: one row per enrichment pass, kept a
--   year. Sparse columns compress ~191:1 (measured on prod), so the cost is
--   noise.
--
-- The compactor and every serving view keep reading biz_enrichment (latest
-- state); this table exists for trend analysis and future "changed since"
-- products.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS ls.biz_enrichment_log AS ls.biz_enrichment
ENGINE = MergeTree
ORDER BY (domain, enriched_at)
TTL enriched_at + INTERVAL 365 DAY;
