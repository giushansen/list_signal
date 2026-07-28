-- SELLABLE INVENTORY: classified businesses with a live site, not flagged.
-- The core asset. Split by business model with contactability signals.
-- (No FINAL: the hourly Optimizer keeps domains_current collapsed; counts are
-- within <1h of inserts of exact.)
SELECT
    business_model,
    count()                                        AS businesses,
    countIf(tranco_rank IS NOT NULL)               AS tranco_ranked,
    countIf(dns_mx != '')                          AS has_mx_email_route,
    countIf(http_emails != '')                     AS has_visible_email,
    countIf(country != '')                         AS has_country,
    round(100 * count() / sum(count()) OVER (), 1) AS share_pct
FROM domains_fast
WHERE business_model != ''
  AND http_status BETWEEN 200 AND 399
  AND is_malware = '' AND is_phishing = ''
GROUP BY business_model
ORDER BY businesses DESC
