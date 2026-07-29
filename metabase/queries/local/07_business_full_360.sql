-- ONE BUSINESS, EVERYTHING WE KNOW — the flat row PLUS its child-table rows.
-- This is the "where do biz_contact / biz_career / biz_pricing show up" answer:
-- they are 1:many, so they are joined in here rather than flattened into
-- `businesses` (which keeps one row per company).
SELECT
    b.domain,
    b.business_model AS model,
    b.http_tech      AS tech,
    b.seo_score,
    b.product_count  AS products,
    -- child tables, aggregated per domain
    c.emails,
    c.email_count,
    p.prices, p.pricing_points,
    j.job_titles,
    j.job_count,
    n.news_count
FROM businesses AS b FINAL
LEFT JOIN (SELECT domain, groupArray(email) AS emails, count() AS email_count
           FROM biz_contact GROUP BY domain) c ON b.domain = c.domain
LEFT JOIN (SELECT domain, arraySort(groupArray(price)) AS prices,
                  count() AS pricing_points FROM biz_pricing GROUP BY domain) p ON b.domain = p.domain
LEFT JOIN (SELECT domain, groupArray(title) AS job_titles, count() AS job_count
           FROM biz_career GROUP BY domain) j ON b.domain = j.domain
LEFT JOIN (SELECT domain, count() AS news_count FROM biz_news GROUP BY domain) n ON b.domain = n.domain
WHERE c.email_count > 0 OR p.pricing_points > 0 OR j.job_count > 0
ORDER BY coalesce(b.tranco_rank, 99999999)
LIMIT 200
