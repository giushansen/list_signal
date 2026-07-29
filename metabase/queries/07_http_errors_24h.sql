-- Crawler error breakdown, last 24h. Watch for one error type suddenly
-- dominating (e.g. tls_error everywhere = egress problem on a worker).
SELECT
    http_error,
    count()                                    AS errors,
    round(count() / max2(1, (SELECT count() FROM domains_history
                             WHERE enriched_at >= now() - INTERVAL 24 HOUR)), 4) AS share_of_all,
    uniqExact(worker)                          AS workers_affected
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 24 HOUR
  AND http_error != ''
GROUP BY http_error
ORDER BY errors DESC
LIMIT 25
