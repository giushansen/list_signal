-- ═══════════════════════════════════════════════════════════════════════════
-- 031 — similar_pool: the candidates for the "businesses like this one"
--       block, pre-selected per (business model, country, revenue tier), so
--       a company page reads one key range instead of scanning the product
--       table (2026-10-28)
--
-- STATUS: apply BEFORE deploying the release that reads it. The INSERT at
-- the end fills the table (one pass over businesses, about a minute on the
-- master, 2 threads, memory capped) so the first page after the deploy
-- finds rows. Safe on a LIVE app: nothing reads the table until the
-- release ships; the release falls back to the old scan while it is empty.
--
-- WHY
--   LS.Clickhouse.similar_stores/6 answers "same model, same country, same
--   revenue tier, best ranked first" from `businesses`, whose sorting key is
--   the domain, so every cache miss is a full scan: 3 to 15 s on the 4-core
--   box that serves customers. The 24 h cache cannot help: the key space is
--   models x countries x tiers x rank bands, and the visitors are crawlers
--   walking /website/* and /shopify/* pages (1,700 of 2,700 sessions in the
--   last 30 days), each on a different company. Measured 2026-10-28 00:00
--   to 06:00 UTC: 176 misses, 3.0 to 5.8 s on average per model, 15.2 s at
--   worst, 710 s of ClickHouse time in six hours, the second largest web
--   cost on the master after the depth refill.
--
-- HOW
--   One row per candidate, at most 80 ranked and 40 recent per group,
--   sorted by (model, country, revenue, kind, rank). The reader's predicate
--   is a prefix of that key: milliseconds. LS.SimilarPool rebuilds it once a
--   day at 11:50 UTC (the quiet hour, right after the daily optimize) into a
--   shadow table and swaps it in, so readers never see an empty pool.
--
--   clickhouse-client -d ls --multiquery < clickhouse/migrations/031_similar_pool.sql
-- ═══════════════════════════════════════════════════════════════════════════

CREATE TABLE IF NOT EXISTS ls.similar_pool
(
    `business_model` LowCardinality(String),
    `country` LowCardinality(String),
    `revenue` LowCardinality(String),
    -- 'ranked': the group's best Tranco ranks. 'recent': unranked members,
    -- newest compiled first (what an unranked target is shown).
    `kind` LowCardinality(String),
    -- Tranco rank for ranked rows; 4294967295 for recent rows, so the key
    -- sorts ranked candidates by rank and keeps recent ones in one range.
    `rank` UInt32,
    `domain` String,
    `http_title` String,
    `tranco_rank` Nullable(Int32),
    `is_shopify` UInt8,
    `compiled_at` DateTime,
    `built_at` DateTime DEFAULT now()
)
ENGINE = MergeTree
ORDER BY (business_model, country, revenue, kind, rank)
SETTINGS index_granularity = 8192;

-- First fill. Identical to LS.SimilarPool.build_sql/1 (pinned by test).
INSERT INTO ls.similar_pool
SELECT business_model, country, revenue, kind, rank, domain, http_title, tranco_rank, is_shopify, compiled_at, now()
FROM (
  SELECT estimated_business_model AS business_model, estimated_country AS country, estimated_revenue AS revenue,
         'ranked' AS kind, toUInt32(tranco_rank) AS rank, domain, http_title, tranco_rank, is_shopify, compiled_at
  FROM businesses FINAL
  WHERE tranco_rank > 0 AND estimated_business_model != '' AND estimated_country != ''
    AND estimated_business_model_confidence >= 0.5 AND estimated_junk = '' AND http_title != ''
  ORDER BY business_model, country, revenue, rank
  LIMIT 80 BY business_model, country, revenue
  UNION ALL
  SELECT estimated_business_model AS business_model, estimated_country AS country, estimated_revenue AS revenue,
         'recent' AS kind, 4294967295 AS rank, domain, http_title, tranco_rank, is_shopify, compiled_at
  FROM businesses FINAL
  WHERE (tranco_rank IS NULL OR tranco_rank <= 0) AND estimated_business_model != '' AND estimated_country != ''
    AND estimated_business_model_confidence >= 0.5 AND estimated_junk = '' AND http_title != ''
    AND compiled_at >= now() - INTERVAL 90 DAY
  ORDER BY business_model, country, revenue, compiled_at DESC
  LIMIT 40 BY business_model, country, revenue
)
SETTINGS max_threads = 2, max_insert_threads = 1, max_execution_time = 900, max_memory_usage = 2500000000, max_bytes_before_external_sort = 1000000000;
