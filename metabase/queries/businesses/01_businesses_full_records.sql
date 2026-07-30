-- Full record: everything both pipelines know, one row per company.
SELECT
    domain, business_model AS model, industry, inferred_country AS country,
    http_title AS title, http_emails AS emails,
    http_tech AS tech, http_apps AS apps,
    dns_a, dns_mx, bgp_asn_org AS hosting, bgp_asn_country AS host_country,
    rdap_registrar AS registrar, rdap_domain_created_at AS domain_created, ctl_issuer AS ssl_issuer,
    ctl_subdomain_count AS subdomains, tranco_rank, majestic_rank,
    estimated_revenue AS revenue, estimated_employees AS employees,
    revenue_confidence AS rev_confidence,
    seo_score, seo_issues, product_count AS products, price_avg, new_products_30d AS new30d,
    vendor_count AS vendors, job_count AS jobs, ats_platform AS ats,
    mission, hq_location, positions_overview, render_engine,
    crawlable, dns_alive, first_seen, last_verified_at, depth_enriched_at
FROM ls.businesses FINAL
ORDER BY coalesce(tranco_rank, 99999999)
LIMIT 300
