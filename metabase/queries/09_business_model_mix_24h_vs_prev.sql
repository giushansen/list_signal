-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- Classifier drift: business_model mix last 24h vs the 24h before.
-- A big share shift with no product change = ML classifier or its inputs broke.
SELECT
    if(business_model = '', '(unclassified)', business_model)                AS model,
    countIf(enriched_at >= now() - INTERVAL 24 HOUR)                         AS last_24h,
    countIf(enriched_at <  now() - INTERVAL 24 HOUR)                         AS prev_24h,
    round(countIf(enriched_at >= now() - INTERVAL 24 HOUR)
          / sum(countIf(enriched_at >= now() - INTERVAL 24 HOUR)) OVER (), 3) AS share_24h,
    round(countIf(enriched_at <  now() - INTERVAL 24 HOUR)
          / sum(countIf(enriched_at <  now() - INTERVAL 24 HOUR)) OVER (), 3) AS share_prev
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 48 HOUR
GROUP BY model
ORDER BY last_24h DESC
