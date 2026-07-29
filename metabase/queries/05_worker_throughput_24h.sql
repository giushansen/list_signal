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
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 24 HOUR
GROUP BY worker
ORDER BY enriched DESC
