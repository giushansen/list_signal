-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- New SaaS discovered in the last 24h, best-ranked first.
SELECT
    domain,
    http_title,
    industry,
    inferred_country                       AS country,
    tranco_rank,
    majestic_rank,
    round(classification_confidence, 2)    AS confidence,
    estimated_revenue,
    enriched_at
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 24 HOUR
  AND business_model = 'SaaS'
ORDER BY coalesce(tranco_rank, 99999999) ASC, enriched_at DESC
LIMIT 200
