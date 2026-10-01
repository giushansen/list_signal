-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- Pipeline throughput per hour over 7 days. A cliff to ~0 = pipeline stalled
-- (dead master, crash-looping workers, queue starvation). Also splits out
-- Shopify + SaaS series so a classifier/detector silently dying is visible
-- even when total volume looks fine.
SELECT
    toStartOfHour(enriched_at)              AS hour,
    count()                                 AS enriched,
    countIf(http_tech LIKE '%Shopify%')     AS shopify,
    countIf(business_model = 'SaaS')        AS saas
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour
