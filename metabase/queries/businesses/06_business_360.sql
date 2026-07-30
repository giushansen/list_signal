-- ONE BUSINESS, EVERYTHING WE KNOW — flat row PLUS child-table rows.
SELECT
    b.domain, b.business_model AS model, b.http_tech AS tech, b.seo_score,
    b.product_count AS products,
    c.emails, c.email_count,
    p.prices, p.pricing_points,
    j.job_titles, j.job_count,
    n.news_count
FROM ls.businesses AS b FINAL
LEFT JOIN (SELECT domain, groupArray(email) AS emails, count() AS email_count
           FROM ls.biz_contact GROUP BY domain) c ON b.domain = c.domain
LEFT JOIN (SELECT domain, arraySort(groupArray(price)) AS prices,
                  count() AS pricing_points FROM ls.biz_pricing GROUP BY domain) p ON b.domain = p.domain
LEFT JOIN (SELECT domain, groupArray(title) AS job_titles, count() AS job_count
           FROM ls.biz_career GROUP BY domain) j ON b.domain = j.domain
LEFT JOIN (SELECT domain, count() AS news_count FROM ls.biz_news GROUP BY domain) n ON b.domain = n.domain
WHERE c.email_count > 0 OR p.pricing_points > 0 OR j.job_count > 0
ORDER BY coalesce(b.tranco_rank, 99999999)
LIMIT 200
