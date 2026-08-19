-- Pipeline 3 — Verification (2026-08-18).
--
-- Authoritative sources (Wikidata, SEC EDGAR, Companies House, Sirene/INPI,
-- YC directory) are ingested on the master and linked to domains we already
-- hold. Three tables, three jobs:
--
--   verification_runs       — one row per fetch/ingest run: what was pulled,
--                             from where, when, how many records, how many
--                             matched per tier. The dated audit trail.
--   verified_source_records — every source record we parsed that carries a
--                             fact we care about, matched or NOT. Persisted so
--                             nobody has to re-download a 2 GB zip to answer
--                             "what did Companies House say about X", and so a
--                             future LLM-assisted linker can work over the
--                             unmatched rows offline.
--   verified_facts          — the product: one fact per (domain, fact, source),
--                             only for records that matched a domain by one
--                             of the two precise tiers. Newest fetched_at wins.
--
-- `businesses` gets sparse verified_* columns filled by the compactor with
-- per-fact source precedence (see LS.Verification). estimated_* is untouched.

CREATE TABLE IF NOT EXISTS ls.verification_runs
(
    `source`      LowCardinality(String),
    `started_at`  DateTime,
    `finished_at` Nullable(DateTime),
    `status`      LowCardinality(String),   -- running|ok|error
    `url`         String,                   -- what was fetched (file or endpoint)
    `snapshot`    String,                   -- source-side version (file date, page, month)
    `bytes`       UInt64,
    `records`     UInt64,                   -- source records parsed
    `matched_website`      UInt64,
    `matched_name_country` UInt64,
    `error`       String,
    `updated_at`  DateTime                  -- version: the run row is re-emitted on finish
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (source, started_at)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS ls.verified_source_records
(
    `source`        LowCardinality(String),
    `source_id`     String,                 -- QID / CIK / company number / SIREN / YC slug
    `name`          String,
    `name_key`      String,                 -- LS.Verification.NameMatch.key/1
    `country`       LowCardinality(String), -- ISO-2 or ''
    `website`       String,                 -- as published by the source
    `website_domain` String,                -- registrable domain of `website`
    `revenue_usd`   Nullable(Float64),
    `revenue_raw`   String,                 -- "1234567 EUR FY2024" — never lose the original
    `employees`     Nullable(UInt32),       -- exact count when the source has one
    `employees_band` String,                -- our bracket label when the source only has a band
    `period`        String,                 -- fiscal year / point in time the fact refers to
    `extra`         String,                 -- JSON: industry, inception, hq, batch, sic, ...
    `matched_domain` String,
    `match_method`  LowCardinality(String), -- website|name_country|''
    `source_url`    String,                 -- where a human can re-check this record
    `fetched_at`    DateTime
)
ENGINE = ReplacingMergeTree(fetched_at)
ORDER BY (source, source_id)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS ls.verified_facts
(
    `domain`       String,
    `fact`         LowCardinality(String),  -- revenue_usd|employees|employees_band|industry|inception|hq|mission
    `source_id`    String,                  -- which source record produced it (audit; joins verified_source_records)
    `value`        String,                  -- normalised (USD integer, count, bracket label, text)
    `raw_value`    String,
    `period`       String,
    `source`       LowCardinality(String),  -- wikidata|sec_edgar|companies_house|sirene|inpi|yc
    `source_url`   String,
    `match_method` LowCardinality(String),  -- website|name_country
    `fetched_at`   DateTime
)
ENGINE = ReplacingMergeTree(fetched_at)
ORDER BY (domain, fact, source)
SETTINGS index_granularity = 8192;

-- Sparse: ~free in ClickHouse (measured 191:1 on prod), and NEW columns only —
-- estimated_* keeps its meaning and its writer.
ALTER TABLE ls.businesses
    ADD COLUMN IF NOT EXISTS `verified_revenue`          LowCardinality(String) DEFAULT '',
    ADD COLUMN IF NOT EXISTS `verified_revenue_source`   LowCardinality(String) DEFAULT '',
    ADD COLUMN IF NOT EXISTS `verified_employees`        LowCardinality(String) DEFAULT '',
    ADD COLUMN IF NOT EXISTS `verified_employees_source` LowCardinality(String) DEFAULT '',
    ADD COLUMN IF NOT EXISTS `mission_summary`           String DEFAULT '';
