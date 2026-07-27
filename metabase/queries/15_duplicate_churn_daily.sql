-- EXACT same-day duplicate churn, per day (30d window).
-- Inner GROUP BY (day, domain) makes the dupe math exact — uniq() HLL noise
-- made this metric meaningless (it went negative) in a single-level query.
-- dupe_rows = rows spent re-enriching a domain already enriched that day.
-- Recrawl cadence is 7/30 days, so anything here is queue churn / waste.
SELECT
    day,
    sum(cnt)                                          AS rows,
    count()                                           AS distinct_domains,
    sum(cnt) - count()                                AS dupe_rows,
    round(100 * (sum(cnt) - count()) / nullIf(sum(cnt), 0), 2) AS dupe_pct,
    max(cnt)                                          AS worst_single_domain,
    countIf(cnt > 1)                                  AS domains_hit_twice_plus
FROM (
    SELECT toDate(enriched_at) AS day, domain, count() AS cnt
    FROM enrichments
    WHERE enriched_at >= now() - INTERVAL 30 DAY
    GROUP BY day, domain
)
GROUP BY day
ORDER BY day
