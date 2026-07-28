-- SHOPIFY STORES — browsable inventory from the curated businesses table.
-- Shopify is TECH, not a business_model: filter on http_tech.
-- (On domains_fast you can use the materialized shortcut `is_shopify = 1`;
--  ls.businesses keeps raw columns only, so LIKE is the way there.)
SELECT
    domain, http_title, industry, inferred_country AS country,
    http_emails, tranco_rank, estimated_revenue,
    http_tech, first_seen, last_verified_at
FROM businesses
WHERE http_tech LIKE '%Shopify%'
  AND crawlable AND dns_alive AND last_http_error = ''
ORDER BY coalesce(tranco_rank, 99999999) ASC
LIMIT 2000
