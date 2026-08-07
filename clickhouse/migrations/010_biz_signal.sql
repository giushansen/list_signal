-- biz_signal: business-relevant change events, one row per observed change.
--
-- Written by the compactor (it holds old and new state in the same pass) and
-- by the one-off history backfill. NOT written by crawlers: a signal is a
-- COMPARISON, and only the compactor sees both sides.
--
-- ReplacingMergeTree so a retried compaction slice re-emitting the identical
-- signal collapses to one row instead of duplicating.
-- ORDER BY (kind, value, ...) serves the money query — "who removed Klaviyo
-- last month" — as an index read.
CREATE TABLE IF NOT EXISTS ls.biz_signal
(
    `kind`       LowCardinality(String),  -- tech_added|tech_removed|app_added|app_removed|started_hiring|stopped_hiring
    `value`      String,                  -- the tech/app name, or the job count for hiring signals
    `domain`     String,
    `changed_at` DateTime
)
ENGINE = ReplacingMergeTree
ORDER BY (kind, value, domain, changed_at)
TTL changed_at + INTERVAL 730 DAY
SETTINGS index_granularity = 8192
