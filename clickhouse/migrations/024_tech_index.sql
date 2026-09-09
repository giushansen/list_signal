-- ═══════════════════════════════════════════════════════════════════════════
-- 024 — tech_index: one row per (technology, titled domain), so the public
--       tech, top, compare and directory pages stop scanning 193M rows
--       (2026-09-09)
--
-- STATUS: apply BEFORE deploying the release that reads it. The INSERT at
-- the end fills the table (about 60s on the master, 147M rows, ~100 MB of
-- memory) so the first request after the deploy finds data. Safe on a LIVE
-- app: nothing reads the table until the release ships.
--
-- WHY
--   Every /tech, /top and /compare page and the sitemap ran
--   `http_tech LIKE '%X%'` over domains_fast, a view on the 193M-row
--   domains_current whose sorting key is the domain. No index can serve
--   that predicate. Measured over 24h on 09-09: 1,844 such queries,
--   29.5s average, 119s at p95, 54,483 CPU-seconds and 7.6 TiB read per
--   day, 72% of all ClickHouse read time together with the other
--   domains_fast readers. It is also the exact shape of the 09-07 storm,
--   where a crawler on invented /tech slugs put 415 concurrent scans on
--   the box and a paying customer saw "Search unavailable".
--
-- WHAT
--   The technologies of every titled domain, exploded one per row and
--   sorted by (tech, rank, domain). A page for one technology reads one
--   contiguous range; the top-100 by rank is the first granules of it.
--   Rebuilt in full every 6 hours by LS.TechIndex (33s read + insert,
--   measured), into a shadow table swapped in with EXCHANGE TABLES so
--   readers never see it empty. The wide columns the page shows
--   (http_title, http_tech, dns_mx, http_emails) ride along because a
--   second lookup by domain against domains_current would cost more than
--   they do here.
--
-- MEANING CHANGES, deliberate
--   * A technology matches by exact token, not substring: "React" no
--     longer counts "React Router" or "Preact", "Vue" no longer counts
--     "Vue.js". The directory already counted by token; the pages now
--     agree with it.
--   * Only titled domains (http_title != '') are indexed. The tech page's
--     own total always had that filter; the directory counts and the
--     language/hosting/registrar distributions did not, so those numbers
--     drop to the titled population. 37.5M of the 82.5M domains with a
--     detected technology carry a title.
--   * Built from domains_current FINAL, so a re-enriched domain counts
--     once even between merges.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS ls.tech_index
(
    `tech` LowCardinality(String),
    `rank` UInt32,                     -- tranco_rank, unranked = 4294967295 (sorts last)
    `domain` String,
    `http_title` String,
    `http_tech` String,
    `country` LowCardinality(String),
    `tranco_rank` Nullable(Int32),
    `majestic_rank` Nullable(Int32),
    `is_shopify` UInt8,
    `http_status` Nullable(Int32),
    `http_response_time` Nullable(Int32),
    `http_language` LowCardinality(String),
    `rdap_registrar` LowCardinality(String),
    `rdap_domain_created_at` Nullable(DateTime),
    `bgp_asn_org` LowCardinality(String),
    `dns_mx` String,
    `http_emails` String,
    `enriched_at` DateTime,
    `built_at` DateTime DEFAULT now()
)
ENGINE = MergeTree
ORDER BY (tech, rank, domain)
SETTINGS index_granularity = 8192;

-- First fill. LS.TechIndex.build_sql/1 is the same statement; keep them in
-- step (LS.TechIndexTest pins the shape).
INSERT INTO ls.tech_index
SELECT
    tech, ifNull(toUInt32(tranco_rank), 4294967295) AS rank, domain, http_title, http_tech, country,
    tranco_rank, majestic_rank, is_shopify, http_status, http_response_time, http_language,
    rdap_registrar, rdap_domain_created_at, bgp_asn_org, dns_mx, http_emails, enriched_at, now()
FROM ls.domains_current FINAL
ARRAY JOIN splitByChar('|', http_tech) AS tech
WHERE http_tech != '' AND http_title != '' AND tech != ''
SETTINGS max_threads = 2, max_insert_threads = 1, max_execution_time = 1700, max_memory_usage = 3000000000;
