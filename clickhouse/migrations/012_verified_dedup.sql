-- Pipeline 3, day 2 (2026-08-19): no duplicate rows for unchanged businesses,
-- history only for meaningful changes.
--
-- v1 keyed verified_source_records on (source, source_id): every monthly
-- re-run re-inserted every record (collapsed lazily by merges) and a CHANGED
-- record replaced the old one — no history. Now the key carries a content
-- hash: the writer skips records whose (source_id, content_hash) already
-- exist (zero rows written for an unchanged business), and a changed record
-- becomes a NEW row next to the old one (the change is the history).
-- verified_facts likewise keys on the value, so a new fiscal year's revenue
-- sits next to last year's; the compactor takes the newest per
-- (domain, fact, source) before applying source precedence.
--
-- Tables were tiny at migration time (~41k records / ~70k facts), so
-- CREATE + INSERT SELECT + RENAME is instant. Existing rows get content_hash
-- '' and are superseded by a hashed row on the next run (one-off).

CREATE TABLE IF NOT EXISTS ls.verified_source_records_v2
(
    `source`        LowCardinality(String),
    `source_id`     String,
    `content_hash`  String,                 -- sha256/16 of the record's content incl. its link
    `name`          String,
    `name_key`      String,
    `country`       LowCardinality(String),
    `website`       String,
    `website_domain` String,
    `revenue_usd`   Nullable(Float64),
    `revenue_raw`   String,
    `employees`     Nullable(UInt32),
    `employees_band` String,
    `period`        String,
    `extra`         String,
    `matched_domain` String,
    `match_method`  LowCardinality(String),
    `source_url`    String,
    `fetched_at`    DateTime
)
ENGINE = ReplacingMergeTree(fetched_at)
ORDER BY (source, source_id, content_hash)
SETTINGS index_granularity = 8192;

INSERT INTO ls.verified_source_records_v2
SELECT source, source_id, '' AS content_hash, name, name_key, country, website, website_domain,
       revenue_usd, revenue_raw, employees, employees_band, period, extra, matched_domain,
       match_method, source_url, fetched_at
FROM ls.verified_source_records;

RENAME TABLE ls.verified_source_records TO ls.verified_source_records_v1,
             ls.verified_source_records_v2 TO ls.verified_source_records;
DROP TABLE ls.verified_source_records_v1;

CREATE TABLE IF NOT EXISTS ls.verified_facts_v2
(
    `domain`       String,
    `fact`         LowCardinality(String),
    `source_id`    String,
    `value`        String,
    `raw_value`    String,
    `period`       String,
    `source`       LowCardinality(String),
    `source_url`   String,
    `match_method` LowCardinality(String),
    `fetched_at`   DateTime
)
ENGINE = ReplacingMergeTree(fetched_at)
ORDER BY (domain, fact, source, value)
SETTINGS index_granularity = 8192;

INSERT INTO ls.verified_facts_v2
SELECT domain, fact, source_id, value, raw_value, period, source, source_url, match_method, fetched_at
FROM ls.verified_facts;

RENAME TABLE ls.verified_facts TO ls.verified_facts_v1,
             ls.verified_facts_v2 TO ls.verified_facts;
DROP TABLE ls.verified_facts_v1;
