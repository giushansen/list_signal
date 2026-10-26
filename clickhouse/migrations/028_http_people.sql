-- 028 (2026-10-26): named people found on a business's pages, one row per
-- (domain, name), written by discovery and the depth lane through
-- LS.Cluster.EnrichmentWriter. A child table like http_contacts, so nothing
-- on enrich_log or businesses changes. Apply once on the master before the
-- release that writes it:
--   clickhouse-client -d ls --multiquery < clickhouse/migrations/028_http_people.sql
CREATE TABLE IF NOT EXISTS ls.http_people
(
    `domain` String,
    `name` String,
    `title` String DEFAULT '',
    `email` String DEFAULT '',
    `source_page` LowCardinality(String),
    `seen_at` DateTime
)
ENGINE = ReplacingMergeTree(seen_at)
ORDER BY (domain, name)
SETTINGS index_granularity = 8192;
