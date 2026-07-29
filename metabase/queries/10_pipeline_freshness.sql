-- Stall detector. minutes_since_last_insert should be ~0-5 at all times
-- (Inserter flushes every 5s). Anything over ~15 min = pipeline is down.
SELECT
    max(enriched_at)                                   AS last_insert,
    dateDiff('minute', max(enriched_at), now())        AS minutes_since_last_insert,
    countIf(enriched_at >= now() - INTERVAL 1 HOUR)    AS rows_last_hour,
    countIf(enriched_at >= now() - INTERVAL 24 HOUR)   AS rows_last_24h,
    uniqExactIf(worker, enriched_at >= now() - INTERVAL 1 HOUR) AS workers_active_last_hour
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 24 HOUR
