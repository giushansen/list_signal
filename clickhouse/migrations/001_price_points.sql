-- ═══════════════════════════════════════════════════════════════════════════
-- 001 — pricing: drop invented plan names, record the currency
--
-- STATUS: NOT YET APPLIED TO PRODUCTION.
--
-- MUST run with the app STOPPED, in the same deploy window as the code that
-- goes with it. `businesses.plan_count` is renamed, and the running release
-- writes `plan_count` on every compaction — renaming underneath a live app is
-- exactly what broke production during the enrichments→domains_history attempt
-- (inserts silently went to zero while SELECTs kept answering).
--
-- WHY
--   biz_pricing.plan_name held `plan_1`, `plan_2`, `plan_3`… — the sort index of
--   the price, not a plan name. Every store's "plan_1" was simply its cheapest
--   observed price. The column read as meaningful data while carrying none, so
--   it is removed rather than left to mislead a customer reading a CSV.
--
--   `currency` replaces it. The extractor already matched $, € and £ and threw
--   the symbol away, which made every number ambiguous — a "25" could be USD,
--   EUR or GBP with no way to tell.
--
-- SAFETY
--   biz_pricing is rebuilt rather than ALTERed because ORDER BY changes, which
--   ALTER cannot do. EXCHANGE TABLES is atomic. The old table is kept as
--   biz_pricing_old until the probe below passes — do not skip that step.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. rebuild biz_pricing with the new key and currency ───────────────────
CREATE TABLE IF NOT EXISTS ls.biz_pricing_new
(
    `domain`   String,
    `price`    Float32,
    `currency` LowCardinality(String),
    `seen_at`  DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, currency, price);

-- Existing rows keep their prices. Currency backfills to USD: the old regex
-- accepted $/€/£ but recorded no symbol, and $ dominates the crawled corpus.
-- This is a stated assumption, not a measurement — rows re-enriched after this
-- migration carry the currency actually printed on the page.
INSERT INTO ls.biz_pricing_new
SELECT domain, price, 'USD' AS currency, seen_at FROM ls.biz_pricing;

EXCHANGE TABLES ls.biz_pricing AND ls.biz_pricing_new;
RENAME TABLE ls.biz_pricing_new TO ls.biz_pricing_old;

-- ── 2. businesses: the count column says what it counts ────────────────────
-- Metadata-only, instant, no data rewritten.
ALTER TABLE ls.businesses RENAME COLUMN plan_count TO pricing_points;

-- ── 3. the customer-facing export view ─────────────────────────────────────
-- Safe to run live (a view reads, never writes), but it must come AFTER the
-- rename above because it selects `pricing_points`. Definition lives in
-- clickhouse/views/v_business_export.sql — apply that file here:
--
--   clickhouse-client --multiquery < clickhouse/views/v_business_export.sql
--
-- Without it, Metabase cannot filter the export at all: filtering a native SQL
-- card makes the driver push a bound parameter into a subquery and fail with
-- "It looks like we got more parameters than we can handle".

-- ── 4. PROBE — run these BEFORE dropping the old table ─────────────────────
--   SELECT count() FROM ls.biz_pricing;      -- must equal biz_pricing_old
--   SELECT count() FROM ls.biz_pricing_old;
--   SELECT name FROM system.columns
--    WHERE database='ls' AND table='businesses' AND name='pricing_points';
--
-- Then start the app and confirm pricing rows still flow:
--   SELECT max(seen_at) FROM ls.biz_pricing;  -- must advance within ~10 min
--
-- ── 5. only once the probe passes ──────────────────────────────────────────
--   DROP TABLE ls.biz_pricing_old;
--
-- ── ROLLBACK (if the probe fails) ──────────────────────────────────────────
--   EXCHANGE TABLES ls.biz_pricing AND ls.biz_pricing_old;
--   ALTER TABLE ls.businesses RENAME COLUMN pricing_points TO plan_count;
--   …then redeploy the previous release.
