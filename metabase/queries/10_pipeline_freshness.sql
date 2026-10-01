-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- Stall detector. minutes_since_last_insert should be ~0-5 at all times
-- (Inserter flushes every 5s). Anything over ~15 min = pipeline is down.
SELECT
    max(enriched_at)                                   AS last_insert,
    dateDiff('minute', max(enriched_at), now())        AS minutes_since_last_insert,
    countIf(enriched_at >= now() - INTERVAL 1 HOUR)    AS rows_last_hour,
    countIf(enriched_at >= now() - INTERVAL 24 HOUR)   AS rows_last_24h,
    uniqExactIf(worker, enriched_at >= now() - INTERVAL 1 HOUR) AS workers_active_last_hour
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 24 HOUR
