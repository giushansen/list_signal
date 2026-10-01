-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- HTTP status class mix: last 24h vs the 24h before. A jump in 5xx or
-- no_response usually means OUR crawler is being blocked/broken, not the web.
SELECT
    multiIf(http_status IS NULL, 'no_response',
            http_status >= 500, '5xx',
            http_status >= 400, '4xx',
            http_status >= 300, '3xx',
            '2xx')                                                           AS status_class,
    countIf(enriched_at >= now() - INTERVAL 24 HOUR)                         AS last_24h,
    countIf(enriched_at <  now() - INTERVAL 24 HOUR)                         AS prev_24h,
    round(countIf(enriched_at >= now() - INTERVAL 24 HOUR)
          / sum(countIf(enriched_at >= now() - INTERVAL 24 HOUR)) OVER (), 3) AS share_24h,
    round(countIf(enriched_at <  now() - INTERVAL 24 HOUR)
          / sum(countIf(enriched_at <  now() - INTERVAL 24 HOUR)) OVER (), 3) AS share_prev
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 48 HOUR
GROUP BY status_class
ORDER BY last_24h DESC
