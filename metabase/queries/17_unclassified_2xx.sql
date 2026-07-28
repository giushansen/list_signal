-- CLASSIFIER ABSTAINED: crawled fine (2xx/3xx) but no business_model.
-- ~5.6M domains — the biggest single expansion pool for sellable inventory.
-- Browse the best-ranked ones to judge what the classifier is missing.
SELECT
    domain, http_title, http_tech, industry, country,
    tranco_rank, dns_mx != '' AS has_mx,
    round(classification_confidence, 2) AS clf_confidence,
    enriched_at
FROM domains_fast
WHERE business_model = ''
  AND http_status BETWEEN 200 AND 399
  AND is_malware = '' AND is_phishing = ''
ORDER BY coalesce(tranco_rank, 99999999) ASC
LIMIT 1000
