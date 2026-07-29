-- BUSINESSES — the compiled product table, FULL record.
-- Everything discovery (pipeline 1) and enrichment (pipeline 2) know about a
-- company, in one row. This is what a CSV export or an API response contains.
SELECT
    domain, business_model AS model, industry, inferred_country AS country,
    http_title AS title, http_emails AS emails,
    -- tech stack (discovery)
    http_tech AS tech, http_apps AS apps,
    -- infrastructure (discovery)
    dns_a, dns_mx, dns_cname, bgp_asn_org AS hosting, bgp_asn_country AS host_country,
    -- registration (discovery)
    rdap_registrar AS registrar, rdap_domain_created_at AS domain_created, ctl_issuer AS ssl_issuer,
    ctl_subdomain_count AS subdomains,
    -- reputation (discovery)
    tranco_rank, majestic_rank,
    -- revenue model (discovery)
    estimated_revenue AS revenue, estimated_employees AS employees,
    revenue_confidence AS rev_confidence, revenue_evidence AS rev_evidence,
    -- depth (enrichment)
    seo_score, seo_issues, product_count AS products, price_avg, new_products_30d AS new30d,
    vendor_count AS vendors, job_count AS jobs, ats_platform AS ats,
    mission, hq_location, positions_overview, render_engine,
    -- lifecycle
    crawlable, dns_alive, first_seen, last_verified_at, depth_enriched_at
FROM businesses FINAL
ORDER BY coalesce(tranco_rank, 99999999)
LIMIT 300
