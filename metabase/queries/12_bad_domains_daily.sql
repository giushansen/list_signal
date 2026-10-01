-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
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
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 90 DAY
GROUP BY day
ORDER BY day
