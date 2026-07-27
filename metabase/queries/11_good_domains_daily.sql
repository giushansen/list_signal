-- GOOD domains per day: real businesses we ingested.
-- "Good" = has real MX records + crawled with a 2xx/3xx + not flagged
-- malware/phishing. Segment %s are among good domains that day.
-- leadgen_sales definition: Agency/Consulting business model in the
-- 'Marketing' industry label (closest labels the classifier emits).
-- Window: 90d (enrichments TTL). Domain-level (uniq), not row-level.
SELECT
    toDate(enriched_at)                                                        AS day,
    uniq(domain)                                                               AS domains_seen,
    uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = '')                   AS good_domains,
    round(100 * good_domains / nullIf(domains_seen, 0), 2)                     AS good_pct,
    uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = ''
                   AND tranco_rank IS NOT NULL)                                AS good_with_tranco,
    round(100 * uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = ''
                   AND business_model = 'Ecommerce')
              / nullIf(good_domains, 0), 1)                                    AS pct_ecommerce,
    round(100 * uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = ''
                   AND http_tech LIKE '%Shopify%')
              / nullIf(good_domains, 0), 1)                                    AS pct_shopify,
    round(100 * uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = ''
                   AND business_model = 'SaaS')
              / nullIf(good_domains, 0), 1)                                    AS pct_saas,
    round(100 * uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = ''
                   AND business_model = 'Agency')
              / nullIf(good_domains, 0), 1)                                    AS pct_agency,
    round(100 * uniqIf(domain, dns_mx != '' AND http_status BETWEEN 200 AND 399
                   AND is_malware = '' AND is_phishing = ''
                   AND business_model IN ('Agency', 'Consulting')
                   AND industry = 'Marketing')
              / nullIf(good_domains, 0), 1)                                    AS pct_leadgen_sales
FROM enrichments
WHERE enriched_at >= now() - INTERVAL 90 DAY
GROUP BY day
ORDER BY day
