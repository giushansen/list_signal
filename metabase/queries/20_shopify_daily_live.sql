-- SHOPIFY DISCOVERY PER DAY — LIVE (reads the append log, not the snapshot,
-- so it updates as workers insert; pair with dashboard auto-refresh).
-- `shopify_seen` counts distinct Shopify domains enriched that day (new +
-- recrawled); `with_email` is the subset carrying a contact address.
SELECT
    toDate(enriched_at)                       AS day,
    uniqExact(domain)                         AS shopify_seen,
    uniqExactIf(domain, http_emails != '')    AS with_email,
    uniqExactIf(domain, dns_mx != '')         AS with_mx
FROM domains_history
WHERE enriched_at >= now() - INTERVAL 30 DAY
  AND http_tech LIKE '%Shopify%'
  AND http_status BETWEEN 200 AND 399
GROUP BY day
ORDER BY day
