-- ═══════════════════════════════════════════════════════════════════════════
-- v_business_unified — the full `businesses` row JOINED with its child rows,
-- one row per business, children as real arrays (not pipe-strings).
--
-- Sibling of v_business_export, different audience:
--   v_business_export  → customer CSV shape: flattened pipe-separated strings
--   v_business_unified → internal browsing: every businesses column (b.*)
--                        plus the matching child rows aggregated as arrays,
--                        so Metabase can filter/inspect without SQL.
--
-- Child columns are prefixed by origin (contact_/pricing_/career_/catalog_)
-- so they can never collide with the businesses columns of similar names
-- (e.g. businesses.job_count vs career_titles here).
--
-- FINAL everywhere: ReplacingMergeTree tables show duplicate (domain, id)
-- rows for re-enriched domains until a background merge runs.
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW ls.v_business_unified AS
SELECT
    -- every businesses column, aliased so the join does not qualify the
    -- names as b.<col> (same trap v_business_export documents).
    b.domain AS domain,
    b.first_seen AS first_seen,
    b.as_of AS as_of,
    b.last_verified_at AS last_verified_at,
    b.last_worker AS last_worker,
    b.crawlable AS crawlable,
    b.last_http_status AS last_http_status,
    b.last_http_error AS last_http_error,
    b.last_http_blocked AS last_http_blocked,
    b.dns_alive AS dns_alive,
    b.ctl_tld AS ctl_tld,
    b.ctl_issuer AS ctl_issuer,
    b.ctl_subdomain_count AS ctl_subdomain_count,
    b.ctl_subdomains AS ctl_subdomains,
    b.dns_a AS dns_a,
    b.dns_aaaa AS dns_aaaa,
    b.dns_mx AS dns_mx,
    b.dns_txt AS dns_txt,
    b.dns_cname AS dns_cname,
    b.http_status AS http_status,
    b.http_response_time AS http_response_time,
    b.http_blocked AS http_blocked,
    b.http_content_type AS http_content_type,
    b.http_tech AS http_tech,
    b.http_apps AS http_apps,
    b.http_language AS http_language,
    b.http_title AS http_title,
    b.http_meta_description AS http_meta_description,
    b.http_pages AS http_pages,
    b.http_emails AS http_emails,
    b.http_h1 AS http_h1,
    b.business_model AS business_model,
    b.industry AS industry,
    b.classification_confidence AS classification_confidence,
    b.http_schema_type AS http_schema_type,
    b.http_og_type AS http_og_type,
    b.bgp_ip AS bgp_ip,
    b.bgp_asn_number AS bgp_asn_number,
    b.bgp_asn_org AS bgp_asn_org,
    b.bgp_asn_country AS bgp_asn_country,
    b.bgp_asn_prefix AS bgp_asn_prefix,
    b.inferred_country AS inferred_country,
    b.rdap_domain_created_at AS rdap_domain_created_at,
    b.rdap_domain_expires_at AS rdap_domain_expires_at,
    b.rdap_domain_updated_at AS rdap_domain_updated_at,
    b.rdap_registrar AS rdap_registrar,
    b.rdap_registrar_iana_id AS rdap_registrar_iana_id,
    b.rdap_nameservers AS rdap_nameservers,
    b.rdap_status AS rdap_status,
    b.tranco_rank AS tranco_rank,
    b.majestic_rank AS majestic_rank,
    b.majestic_ref_subnets AS majestic_ref_subnets,
    b.is_disposable_email AS is_disposable_email,
    b.estimated_revenue AS estimated_revenue,
    b.estimated_employees AS estimated_employees,
    b.revenue_confidence AS revenue_confidence,
    b.revenue_evidence AS revenue_evidence,
    b.product_count AS product_count,
    b.price_min AS price_min,
    b.price_avg AS price_avg,
    b.price_max AS price_max,
    b.new_products_30d AS new_products_30d,
    b.last_product_at AS last_product_at,
    b.oos_ratio AS oos_ratio,
    b.discount_depth AS discount_depth,
    b.vendor_count AS vendor_count,
    b.catalog_age_days AS catalog_age_days,
    b.product_types AS product_types,
    b.job_count AS job_count,
    b.ats_platform AS ats_platform,
    b.job_departments AS job_departments,
    b.job_locations AS job_locations,
    b.seo_score AS seo_score,
    b.seo_issues AS seo_issues,
    b.seo_word_count AS seo_word_count,
    b.seo_alt_ratio AS seo_alt_ratio,
    b.perf_lcp_ms AS perf_lcp_ms,
    b.perf_cls AS perf_cls,
    b.perf_ttfb_ms AS perf_ttfb_ms,
    b.render_engine AS render_engine,
    b.depth_enriched_at AS depth_enriched_at,
    b.pricing_points AS pricing_points,
    b.about_text AS about_text,
    b.mission AS mission,
    b.hq_location AS hq_location,
    b.job_locations_top AS job_locations_top,
    b.positions_overview AS positions_overview,
    b.news_count AS news_count,
    b.last_funding_usd AS last_funding_usd,
    c.contact_emails,
    c.contact_count,
    p.pricing_observed,
    p.pricing_currencies,
    j.career_titles,
    j.career_locations,
    pr.catalog_titles,
    pr.catalog_rows,
    col.collection_titles,
    n.news_headlines
-- Scoped to DEEP-ENRICHED businesses: child rows only exist for domains
-- pipeline 2 has visited, and without this filter the view FINAL-scans all
-- 6.7M businesses before joining — minutes per query. The full population
-- stays browsable in the plain `businesses` table card.
FROM (
    SELECT * FROM ls.businesses FINAL
    WHERE domain IN (SELECT domain FROM ls.biz_enrichment)
) AS b
LEFT JOIN (
    SELECT domain, groupArray(email) AS contact_emails, count() AS contact_count
    FROM ls.biz_contact FINAL GROUP BY domain
) c ON b.domain = c.domain
LEFT JOIN (
    SELECT domain,
           arraySort(groupArray(price)) AS pricing_observed,
           groupUniqArray(currency)     AS pricing_currencies
    FROM ls.biz_pricing FINAL GROUP BY domain
) p ON b.domain = p.domain
LEFT JOIN (
    SELECT domain, groupArray(title) AS career_titles,
           groupUniqArray(location)  AS career_locations
    FROM ls.biz_career FINAL GROUP BY domain
) j ON b.domain = j.domain
LEFT JOIN (
    -- Sliced: a 250-product store would make the row unreadable; the full
    -- catalog stays one click away in Browse: biz_products.
    SELECT domain, arraySlice(groupArray(title), 1, 25) AS catalog_titles,
           count() AS catalog_rows
    FROM ls.biz_products FINAL GROUP BY domain
) pr ON b.domain = pr.domain
LEFT JOIN (
    SELECT domain, arraySlice(groupArray(title), 1, 25) AS collection_titles
    FROM ls.biz_collections FINAL GROUP BY domain
) col ON b.domain = col.domain
LEFT JOIN (
    SELECT domain, groupArray(title) AS news_headlines
    FROM ls.biz_news FINAL GROUP BY domain
) n ON b.domain = n.domain
;
