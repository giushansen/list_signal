-- ★ THE EXPORT — one line per business, everything we know.
--
-- This is what a customer CSV download looks like: one row per company, with
-- contacts / price points / job titles / news headlines flattened into
-- pipe-separated columns so a business never spans multiple rows.
--
-- Backed by the ls.v_business_export VIEW (clickhouse/views/v_business_export.sql),
-- NOT by inline SQL. That is deliberate: Metabase can filter and scan a view
-- like a table, but it cannot push a filter into a native SQL card — it wraps
-- the card in a subquery with a bound parameter, and the ClickHouse driver
-- rejects that with "It looks like we got more parameters than we can handle".
-- Anyone typing "shopify" into the filter bar on a native card gets a 500.
--
-- Two distinct price families, named so they cannot be confused:
--   product_price_*   what the store SELLS   (Shopify catalog)
--   pricing_*         what the vendor CHARGES (its own pricing page)

SELECT * FROM v_business_export
ORDER BY coalesce(tranco_rank, 99999999)
LIMIT 200
