-- Shopify stores with catalog intelligence (pipeline 2 /products.json).
SELECT
    domain, inferred_country AS country, product_count AS products,
    price_avg, price_min, price_max, new_products_30d AS new30d,
    vendor_count AS vendors, oos_ratio, discount_depth,
    seo_score, substring(product_types, 1, 50) AS types, http_emails AS emails
FROM ls.businesses FINAL
WHERE http_tech LIKE '%Shopify%' AND product_count IS NOT NULL
ORDER BY product_count DESC
LIMIT 300
