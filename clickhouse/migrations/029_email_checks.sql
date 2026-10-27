-- 029 (2026-10-27): one row per published address with its deliverability
-- score, verdict and evidence (LS.Email.Score). No SMTP handshake, by
-- decision: scored from where it was published, what it is for the
-- business, the domain's mail setup and how recently it was seen. Written
-- by LS.Email.Verifier on every contact row and backfilled once from
-- `businesses` (LS.Email.Verifier.backfill/0). Apply on the master before
-- the release that writes it:
--   clickhouse-client -d ls --multiquery < clickhouse/migrations/029_email_checks.sql
CREATE TABLE IF NOT EXISTS ls.email_checks
(
    `domain` String,
    `email` String,
    `kind` LowCardinality(String),
    `score` UInt8,
    `verdict` LowCardinality(String),
    `evidence` Array(String),
    `provider` LowCardinality(String),
    `source_page` LowCardinality(String),
    `last_seen` Nullable(DateTime),
    `checked_at` DateTime
)
ENGINE = ReplacingMergeTree(checked_at)
ORDER BY (domain, email)
SETTINGS index_granularity = 8192;
