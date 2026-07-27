-- BAD / suspicious domains per day.
--   flagged_*        blocklist hits (malware / phishing / disposable-email)
--   dead_dns         CT-log cert but domain doesn't resolve at all
--   parked_hint      resolves but empty site: no MX, no title, never got 2xx
-- Same-day duplicate churn lives in 15_duplicate_churn_daily.sql — it needs
-- exact two-level aggregation; uniq() HLL noise made it negative here.
SELECT
    toDate(enriched_at)                                                        AS day,
    count()                                                                    AS rows,
    uniq(domain)                                                               AS domains,
    uniqIf(domain, is_malware = 'true')                                        AS flagged_malware,
    uniqIf(domain, is_phishing = 'true')                                       AS flagged_phishing,
    uniqIf(domain, is_disposable_email = 'true')                               AS flagged_disposable,
    uniqIf(domain, dns_a = '' AND dns_cname = '')                              AS dead_dns,
    round(100 * uniqIf(domain, dns_a = '' AND dns_cname = '')
              / nullIf(uniq(domain), 0), 2)                                    AS dead_dns_pct,
    uniqIf(domain, dns_a != '' AND dns_mx = '' AND http_title = ''
                   AND (http_status IS NULL OR http_status >= 400))            AS parked_hint
FROM enrichments
WHERE enriched_at >= now() - INTERVAL 90 DAY
GROUP BY day
ORDER BY day
