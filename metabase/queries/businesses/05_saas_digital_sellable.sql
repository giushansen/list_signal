-- SaaS / digital businesses with the depth signals that make a record sellable.
SELECT
    domain, business_model AS model, industry, inferred_country AS country,
    tranco_rank, http_emails AS emails,
    seo_score, substring(seo_issues, 1, 45) AS seo_issues,
    job_count AS jobs, ats_platform AS ats, positions_overview,
    substring(mission, 1, 70) AS mission, hq_location
FROM ls.businesses FINAL
WHERE business_model IN ('SaaS','Tool','Marketplace','Agency')
ORDER BY coalesce(tranco_rank, 99999999)
LIMIT 300
