-- ═══════════════════════════════════════════════════════════════════════════
-- 021 — reverse DNS + Microsoft enterprise records, sitemap snapshot, and a
--       depth-pass revenue estimate (2026-09-06)
--
-- STATUS: apply BEFORE deploying the release that writes these. Additive
-- only, safe on a LIVE app.
--
-- WHY
--   dns_ptr / dns_ms_enterprise (LS.DNS.Infra): reverse DNS of the web host
--   tells dedicated infrastructure from shared hosting; the
--   _autodiscover._tcp / _sipfederationtls._tcp SRV records and the
--   enterpriseregistration CNAME exist only where a company runs Exchange,
--   Teams federation or Entra/Intune device enrolment. Size signals for
--   the revenue estimator that no web page shows.
--
--   sitemap_* (LS.Enrichment.Sitemap): one small row per business from the
--   sitemap the domain's robots.txt names (or /sitemap.xml): URL count,
--   product/blog URL counts, child sitemap count, newest lastmod, and a
--   64-bit simhash of the URL set for change detection. Page count is one
--   of the best public proxies for company size; the hash makes "site
--   restructured" a change signal.
--
--   depth_estimated_* (biz_enrichment): the revenue estimator re-run by the
--   depth pass with everything it knows (catalog, apps, sitemap, jobs, DNS)
--   on top of the discovery row. The compactor prefers it over the
--   discovery-time estimate when present.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE ls.domains_history
  ADD COLUMN IF NOT EXISTS dns_ptr String DEFAULT '',
  ADD COLUMN IF NOT EXISTS dns_ms_enterprise LowCardinality(String) DEFAULT '';

ALTER TABLE ls.businesses
  ADD COLUMN IF NOT EXISTS dns_ptr String DEFAULT '',
  ADD COLUMN IF NOT EXISTS dns_ms_enterprise LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS sitemap_urls Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_products Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_blog Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_children Nullable(UInt16),
  ADD COLUMN IF NOT EXISTS sitemap_lastmod Nullable(DateTime),
  ADD COLUMN IF NOT EXISTS sitemap_hash Nullable(UInt64);

ALTER TABLE ls.biz_enrichment
  ADD COLUMN IF NOT EXISTS sitemap_urls Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_products Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_blog Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_children Nullable(UInt16),
  ADD COLUMN IF NOT EXISTS sitemap_lastmod Nullable(DateTime),
  ADD COLUMN IF NOT EXISTS sitemap_hash Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS depth_estimated_revenue LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS depth_estimated_employees LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS depth_revenue_confidence Nullable(Float32),
  ADD COLUMN IF NOT EXISTS depth_revenue_evidence String DEFAULT '';

ALTER TABLE ls.biz_enrichment_log
  ADD COLUMN IF NOT EXISTS sitemap_urls Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_products Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_blog Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS sitemap_children Nullable(UInt16),
  ADD COLUMN IF NOT EXISTS sitemap_lastmod Nullable(DateTime),
  ADD COLUMN IF NOT EXISTS sitemap_hash Nullable(UInt64),
  ADD COLUMN IF NOT EXISTS depth_estimated_revenue LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS depth_estimated_employees LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS depth_revenue_confidence Nullable(Float32),
  ADD COLUMN IF NOT EXISTS depth_revenue_evidence String DEFAULT '';
