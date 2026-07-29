-- New SaaS discovered in the last 24h, best-ranked first.
SELECT
    domain,
    http_title,
    industry,
    inferred_country                       AS country,
    tranco_rank,
    majestic_rank,
    round(classification_confidence, 2)    AS confidence,
    estimated_revenue,
    enriched_at
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 24 HOUR
  AND business_model = 'SaaS'
ORDER BY coalesce(tranco_rank, 99999999) ASC, enriched_at DESC
LIMIT 200
