-- ═══════════════════════════════════════════════════════════════════════════
-- v_business_export — one row per business, everything we know, flattened.
--
-- This is the customer-facing shape: exactly what a CSV download looks like.
-- The one-to-many child tables (contacts, price points, jobs, news) are
-- collapsed into pipe-separated columns so a business never spans two rows.
--
-- Why a VIEW and not a saved query: Metabase (and any BI tool) can filter and
-- scan a view like a table. A native SQL card cannot be filtered on top of —
-- the tool has to wrap it in a subquery and push down a bound parameter, which
-- the ClickHouse driver rejects with "more parameters than we can handle".
-- Publishing this as a view is what makes the filter/scan bar work at all.
--
-- Every child-table join uses FINAL. These are ReplacingMergeTree tables keyed
-- on (domain, id), so until a background merge runs, a re-enriched domain has
-- two rows per item. Without FINAL a store with a 250-product cap reported 500
-- products and 200 collections after its second enrichment.
--
-- Naming rule enforced here: there are TWO unrelated sets of prices and they
-- used to collide.
--   product_price_*  → the Shopify catalog (what the store sells)
--   pricing_*        → the vendor's own pricing page (what the vendor charges)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE VIEW ls.v_business_export AS
SELECT
    -- ── identity ──────────────────────────────────────────────────────────
    -- Aliased explicitly: `domain` also exists in all four joined subqueries,
    -- so without this ClickHouse keeps the qualifier and names the column
    -- `b.domain`, which no downstream query can reference.
    b.domain                                        AS domain,
    b.http_title                                    AS title,
    b.business_model                                AS model,
    b.industry,
    -- The hosting/commerce platform, so "shopify" is findable in one column
    -- instead of buried in a pipe-separated tech string.
    multiIf(
      b.product_count > 0
        OR positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'shopify') > 0, 'Shopify',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'woocommerce')  > 0, 'WooCommerce',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'bigcommerce')  > 0, 'BigCommerce',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'magento')      > 0, 'Magento',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'squarespace')  > 0, 'Squarespace',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'webflow')      > 0, 'Webflow',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'wix')          > 0, 'Wix',
      positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'wordpress')    > 0, 'WordPress',
      '')                                           AS platform,
    b.inferred_country                              AS country,
    b.http_language                                 AS language,

    -- ── contact ───────────────────────────────────────────────────────────
    concat_ws('|', b.http_emails, c.emails)         AS all_emails,
    c.email_count,
    b.dns_mx != ''                                  AS has_mail,

    -- ── tech ──────────────────────────────────────────────────────────────
    b.http_tech                                     AS tech,
    b.http_apps                                     AS apps,

    -- ── infrastructure ────────────────────────────────────────────────────
    b.dns_a, b.dns_mx, b.dns_cname, b.dns_txt,
    b.bgp_asn_org                                   AS hosting,
    b.bgp_asn_country                               AS hosting_country,
    b.bgp_ip,

    -- ── registration ──────────────────────────────────────────────────────
    b.rdap_registrar                                AS registrar,
    b.rdap_domain_created_at                        AS domain_created,
    dateDiff('day', b.rdap_domain_created_at, now()) AS domain_age_days,
    b.rdap_nameservers                              AS nameservers,
    b.ctl_issuer                                    AS ssl_issuer,
    b.ctl_subdomain_count                           AS subdomains,

    -- ── reputation ────────────────────────────────────────────────────────
    b.tranco_rank, b.majestic_rank,
    b.majestic_ref_subnets                          AS ref_subnets,

    -- ── revenue ───────────────────────────────────────────────────────────
    b.estimated_revenue                             AS revenue,
    b.estimated_employees                           AS employees,
    b.revenue_confidence,
    b.revenue_evidence                              AS revenue_why,

    -- ── commerce: what the store SELLS (Shopify catalog) ──────────────────
    b.product_count                                 AS products,
    b.price_min                                     AS product_price_min,
    b.price_avg                                     AS product_price_avg,
    b.price_max                                     AS product_price_max,
    b.new_products_30d, b.vendor_count              AS vendors,
    b.oos_ratio, b.discount_depth, b.catalog_age_days, b.product_types,
    -- A sample of what the store actually sells, and its own merchandising
    -- taxonomy. The aggregates say how big a catalog is; these say what it IS.
    pr.top_products                                 AS top_products,
    pr.stored_products                              AS products_stored,
    col.collection_names                            AS collections,
    col.collection_count                            AS collections_count,

    -- ── pricing: what the vendor CHARGES (its own pricing page) ───────────
    -- Observed price points, ascending. Not named tiers — see LS.Enrichment.Agent.
    p.price_list                                    AS pricing_observed,
    p.price_low                                     AS pricing_low,
    p.price_high                                    AS pricing_high,
    p.currency                                      AS pricing_currency,
    b.pricing_points,

    -- ── hiring ────────────────────────────────────────────────────────────
    b.job_count, b.ats_platform AS ats, b.job_departments, b.job_locations,
    j.job_titles,

    -- ── company profile ───────────────────────────────────────────────────
    b.mission, b.hq_location, b.positions_overview, b.about_text,

    -- ── news / funding ────────────────────────────────────────────────────
    n.news_titles, b.news_count, b.last_funding_usd,

    -- ── SEO & performance ─────────────────────────────────────────────────
    b.seo_score, b.seo_issues, b.seo_word_count, b.seo_alt_ratio,
    b.perf_lcp_ms, b.perf_cls, b.perf_ttfb_ms,

    -- ── lifecycle ─────────────────────────────────────────────────────────
    b.crawlable, b.dns_alive, b.last_http_status, b.last_http_error,
    b.last_http_blocked, b.render_engine,
    b.first_seen, b.last_verified_at, b.depth_enriched_at

FROM businesses AS b FINAL
LEFT JOIN (
    SELECT domain,
           arrayStringConcat(groupArray(email), '|') AS emails,
           count()                                   AS email_count
    FROM biz_contact FINAL GROUP BY domain
) c ON b.domain = c.domain
LEFT JOIN (
    -- Sorted ascending so the list reads as a price ladder: 7|10|19|25|99
    SELECT domain,
           arrayStringConcat(arrayMap(x -> toString(x), arraySort(groupArray(price))), '|') AS price_list,
           min(price)      AS price_low,
           max(price)      AS price_high,
           any(currency)   AS currency
    FROM biz_pricing FINAL GROUP BY domain
) p ON b.domain = p.domain
LEFT JOIN (
    SELECT domain, arrayStringConcat(groupArray(title), '|') AS job_titles
    FROM biz_career FINAL GROUP BY domain
) j ON b.domain = j.domain
LEFT JOIN (
    SELECT domain, arrayStringConcat(groupArray(title), '|') AS news_titles
    FROM biz_news FINAL GROUP BY domain
) n ON b.domain = n.domain
LEFT JOIN (
    -- Sliced to 15: a CSV cell holding 250 product titles is unreadable, and
    -- the full catalog is one query away in biz_products.
    SELECT domain,
           arrayStringConcat(arraySlice(groupArray(title), 1, 15), '|') AS top_products,
           count()                                                      AS stored_products
    FROM biz_products FINAL GROUP BY domain
) pr ON b.domain = pr.domain
LEFT JOIN (
    SELECT domain,
           arrayStringConcat(arraySlice(groupArray(title), 1, 25), '|') AS collection_names,
           count()                                                      AS collection_count
    FROM biz_collections FINAL GROUP BY domain
) col ON b.domain = col.domain
;
