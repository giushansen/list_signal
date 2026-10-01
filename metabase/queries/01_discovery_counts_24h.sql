-- 2026-10-01: table names updated for data model v2 (see docs/data-model-standards.md).
-- Column names on `businesses` keep working through legacy ALIAS columns for one release;
-- changes_log replaced biz_signal (kind -> field + change). Re-check this query in Metabase.
-- Headline numbers: what the pipeline found in the last 24h.
-- Source: enrich_log (append log). is_shopify only exists on domains_fast,
-- so we use the same expression the MV materializes: http_tech LIKE '%Shopify%'.
SELECT
    count()                                          AS enriched_total,
    countIf(http_tech LIKE '%Shopify%')              AS shopify,
    countIf(business_model = 'SaaS')                 AS saas,
    countIf(business_model = 'Ecommerce')            AS ecommerce,
    countIf(business_model = 'Marketplace')          AS marketplace,
    uniqExact(domain)                                AS unique_domains
FROM enrich_log
WHERE enriched_at >= now() - INTERVAL 24 HOUR
