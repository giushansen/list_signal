-- CRAWL GAP on LEGIT domains, per day.
-- Legit = Tranco-ranked OR has real MX records — a domain we *know* matters.
-- Splits the ones we don't have content for into:
--   never_attempted   the high-value-TLD gate skipped it (coverage gap)
--   rate_limited/waf/tls/timeout/other  we tried and failed (capability gap)
-- need_better_crawler_pct = failures / attempts among legit domains: the %
-- of legit sites our current crawler cannot fetch.
SELECT
    toDate(enriched_at)                                                        AS day,
    uniqIf(domain, tranco_rank IS NOT NULL OR dns_mx != '')                    AS legit_domains,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND (http_status IS NOT NULL OR http_error != ''
                        OR http_blocked != ''))                                AS attempted,
    round(100 * (legit_domains - attempted) / nullIf(legit_domains, 0), 1)     AS never_attempted_pct,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND http_status BETWEEN 200 AND 399)                        AS crawl_ok,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND http_error = 'rate_limited')                            AS rate_limited,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND http_blocked != '')                                     AS waf_blocked,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND http_error LIKE 'transport:{:tls%')                     AS tls_failed,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND http_error IN ('transport::timeout', 'receive_timeout'))AS timed_out,
    uniqIf(domain, (tranco_rank IS NOT NULL OR dns_mx != '')
                   AND http_status >= 400)                                     AS http_4xx_5xx,
    round(100 * (attempted - crawl_ok) / nullIf(attempted, 0), 1)              AS need_better_crawler_pct
FROM enrichments
WHERE enriched_at >= now() - INTERVAL 90 DAY
GROUP BY day
ORDER BY day
