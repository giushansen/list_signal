-- Pipeline throughput per hour over 7 days. A cliff to ~0 = pipeline stalled
-- (dead master, crash-looping workers, queue starvation). Also splits out
-- Shopify + SaaS series so a classifier/detector silently dying is visible
-- even when total volume looks fine.
SELECT
    toStartOfHour(enriched_at)              AS hour,
    count()                                 AS enriched,
    countIf(http_tech LIKE '%Shopify%')     AS shopify,
    countIf(business_model = 'SaaS')        AS saas
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 7 DAY
GROUP BY hour
ORDER BY hour
