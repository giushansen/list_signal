-- ═══════════════════════════════════════════════════════════════════════════
-- 023 — provenance: which build produced a row, what the detectors saw,
--       which tier chose the business model (2026-09-06)
--
-- STATUS: apply BEFORE deploying the release that writes these. Additive
-- only, safe on a LIVE app.
--
-- WHY
--   A wrong value could be traced to a time, never to a cause. Every crawl
--   row now carries the build it came from (pipeline_version, the git
--   revision), a 2 KB fingerprint of the evidence the detectors had
--   (script hosts, generator meta, server headers, size), and the tier that
--   chose the business model (heuristic, or ml:<head version>). Enrichment
--   rows carry the build too. With these, a claimed change event can be
--   checked against the evidence the crawler actually saw, a signature can
--   be replayed over stored fingerprints instead of re-crawling, and a
--   classifier regression can be measured by comparing rows before and
--   after a revision.
-- ═══════════════════════════════════════════════════════════════════════════
ALTER TABLE ls.domains_history
  ADD COLUMN IF NOT EXISTS http_fingerprint String DEFAULT '',
  ADD COLUMN IF NOT EXISTS pipeline_version LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS classification_source LowCardinality(String) DEFAULT '';

ALTER TABLE ls.businesses
  ADD COLUMN IF NOT EXISTS pipeline_version LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS classification_source LowCardinality(String) DEFAULT '';

ALTER TABLE ls.biz_enrichment ADD COLUMN IF NOT EXISTS pipeline_version LowCardinality(String) DEFAULT '';
ALTER TABLE ls.biz_enrichment_log ADD COLUMN IF NOT EXISTS pipeline_version LowCardinality(String) DEFAULT '';
