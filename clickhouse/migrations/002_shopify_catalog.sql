-- The Shopify catalog itself. Aggregates on `businesses` answer "how big is
-- this store"; these answer "what does it actually sell" — the question a
-- customer prospecting a niche needs answered.
CREATE TABLE IF NOT EXISTS ls.biz_products
(
    domain        String,
    product_id    UInt64,
    title         String,
    handle        String,
    vendor        String,
    product_type  String,
    price         Nullable(Float32),
    available     UInt8,
    variant_count UInt16,
    image_count   UInt16,
    created_at    Nullable(DateTime),
    seen_at       DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, product_id);

-- The store's own merchandising taxonomy, which is far more meaningful than
-- the free-text product_type field most stores leave blank.
CREATE TABLE IF NOT EXISTS ls.biz_collections
(
    domain         String,
    collection_id  UInt64,
    title          String,
    handle         String,
    products_count UInt32,
    updated_at     Nullable(DateTime),
    seen_at        DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, collection_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- STATUS: NOT YET APPLIED TO PRODUCTION.
--
-- Safe to run on a LIVE app: these are new tables, nothing is renamed and no
-- existing column changes. The writer only starts populating them once the
-- matching release is deployed.
--
-- Also required in this deploy (both are code-only, no DDL):
--   * businesses drops is_malware / is_phishing / seo_internal_links /
--     seo_external_links — see 003_drop_dead_columns.sql
--   * the export view must be re-applied to pick up the new joins:
--       clickhouse-client --multiquery < clickhouse/views/v_business_export.sql
-- ═══════════════════════════════════════════════════════════════════════════
