-- DOMAINS_HISTORY — pipeline 1's append log, one row per crawl.
-- (Still named `enrichments` until migrate_pipeline2.sh runs on a node.)
SELECT
    enriched_at, domain, ctl_tld AS tld, http_status AS status,
    substring(http_title, 1, 45)  AS title,
    substring(http_tech, 1, 40)   AS tech,
    business_model, inferred_country AS country,
    dns_mx != '' AS has_mx, tranco_rank, worker
FROM domains_history
ORDER BY enriched_at DESC
LIMIT 500
