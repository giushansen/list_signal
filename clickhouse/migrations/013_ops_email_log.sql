-- Ops email log (2026-08-23): one row per alert/report email actually sent.
-- Serves two jobs from one place: per-alert-key COOLDOWN (don't re-send the
-- same condition within its window) and weekly-report DEDUP (survives a master
-- restart, so a reboot cannot double-send). Tiny and append-only.
CREATE TABLE IF NOT EXISTS ls.ops_email_log
(
    `key`     LowCardinality(String),   -- alert key, or 'weekly_report'
    `sent_at` DateTime,
    `subject` String
)
ENGINE = MergeTree
ORDER BY (key, sent_at)
TTL sent_at + INTERVAL 180 DAY
SETTINGS index_granularity = 8192;
