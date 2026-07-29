-- What pipeline 2 has produced across every child table.
-- (ORDER BY wraps the UNION: an alias from the first branch is not visible to
--  the others, so ClickHouse rejects `ORDER BY rows` applied directly.)
SELECT * FROM (
    SELECT 'biz_contact'    AS table, count() AS rows, uniqExact(domain) AS domains FROM biz_contact
    UNION ALL SELECT 'biz_career',    count(), uniqExact(domain) FROM biz_career
    UNION ALL SELECT 'biz_pricing',   count(), uniqExact(domain) FROM biz_pricing
    UNION ALL SELECT 'biz_news',      count(), uniqExact(domain) FROM biz_news
    UNION ALL SELECT 'biz_enrichment', count(), uniqExact(domain) FROM biz_enrichment
)
ORDER BY rows DESC
