-- CRAWLED BUT 4xx/5xx: got an HTTP status, no page body to classify.
-- ~1.1M domains. 401/403 = often WAF-fronted REAL businesses (crawler gap);
-- 404/410 on apex = candidate dead/out-of-business signal.
SELECT
    http_status,
    count()                          AS domains,
    countIf(tranco_rank IS NOT NULL) AS tranco_ranked,
    countIf(dns_mx != '')            AS has_mx
FROM domains_fast
WHERE business_model = ''
  AND http_status >= 400
GROUP BY http_status
ORDER BY domains DESC
LIMIT 20
