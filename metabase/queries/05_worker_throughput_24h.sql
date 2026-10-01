-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- Per-worker throughput, last 24h. Expect 6 workers (7 with h1).
-- A missing row = worker down/disconnected. A stale last_seen = worker hung.
-- syd1 chronically low is a known issue (outbound TLS/RDAP), not the cluster.
SELECT
    worker,
    count()                                          AS enriched,
    max(enriched_at)                                 AS last_seen,
    dateDiff('minute', max(enriched_at), now())      AS minutes_since_last,
    round(avg(http_status IS NULL), 3)               AS http_null_ratio,
    round(avg(dns_a = ''), 3)                        AS dns_empty_ratio
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 24 HOUR
GROUP BY worker
ORDER BY enriched DESC
