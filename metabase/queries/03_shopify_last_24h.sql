-- New Shopify stores discovered in the last 24h, best-ranked first.
SELECT
    domain,
    http_title,
    industry,
    inferred_country                       AS country,
    tranco_rank,
    estimated_revenue,
    enriched_at
FROM enrichments
WHERE enriched_at >= now() - INTERVAL 24 HOUR
  AND http_tech LIKE '%Shopify%'
ORDER BY coalesce(tranco_rank, 99999999) ASC, enriched_at DESC
LIMIT 200
