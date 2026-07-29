-- BLACKLIST candidates: domains we keep re-enriching that have never shown
-- any business value — no MX, no Tranco/Majestic rank, never returned 2xx/3xx.
-- Every row spent on these is pure waste; feed the worst into a skip-list.
-- Pre-filtered to the junk subset BEFORE grouping to keep memory sane.
-- Window: 30d. seen_days > 3 = it keeps coming back through CT/recrawl.
SELECT
    domain,
    count()                                        AS times_enriched,
    uniq(toDate(enriched_at))                      AS seen_days,
    min(enriched_at)                               AS first_seen,
    max(enriched_at)                               AS last_seen,
    any(ctl_tld)                                   AS tld,
    anyIf(http_error, http_error != '')            AS sample_error,
    countIf(is_malware = 'true' OR is_phishing = 'true') > 0 AS flagged
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 30 DAY
  AND dns_mx = ''
  AND tranco_rank IS NULL
  AND majestic_rank IS NULL
  AND (http_status IS NULL OR http_status >= 400)
GROUP BY domain
HAVING times_enriched >= 5 AND seen_days >= 3
ORDER BY times_enriched DESC
LIMIT 500
