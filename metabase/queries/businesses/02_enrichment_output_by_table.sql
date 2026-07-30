-- What pipeline 2 has produced across every child table.
SELECT * FROM (
    SELECT 'biz_contact'     AS table, count() AS rows, uniqExact(domain) AS domains FROM ls.biz_contact
    UNION ALL SELECT 'biz_career',     count(), uniqExact(domain) FROM ls.biz_career
    UNION ALL SELECT 'biz_pricing',    count(), uniqExact(domain) FROM ls.biz_pricing
    UNION ALL SELECT 'biz_products',   count(), uniqExact(domain) FROM ls.biz_products
    UNION ALL SELECT 'biz_collections',count(), uniqExact(domain) FROM ls.biz_collections
    UNION ALL SELECT 'biz_news',       count(), uniqExact(domain) FROM ls.biz_news
    UNION ALL SELECT 'biz_enrichment', count(), uniqExact(domain) FROM ls.biz_enrichment
)
ORDER BY rows DESC
