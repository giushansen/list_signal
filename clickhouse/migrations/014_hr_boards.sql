-- Registry of ATS/job-platform boards: the durable slug inventory.
--
-- The Jobs enricher discovers a board only when it recrawls a company's
-- careers page; this table makes every discovered board a standing asset that
-- BoardSync re-reads directly from the platform's public JSON on a weekly
-- cadence, so hiring data stays fresh WITHOUT waiting for a site recrawl.
-- Rows come from (a) extraction over biz_career posting URLs and (b) platform
-- directory ingests (Welcome to the Jungle).
CREATE TABLE IF NOT EXISTS ls.hr_boards
(
    `platform`    LowCardinality(String),  -- greenhouse|lever|ashby|workable|smartrecruiters|recruitee|wttj|...
    `slug`        String,                  -- board identifier on the platform
    `domain`      String,                  -- company website domain ('' until resolved)
    `company`     String,                  -- display name when the platform gives one
    `country`     LowCardinality(String),  -- hint from the platform ('' unknown)
    `first_seen`  DateTime DEFAULT now(),
    `last_synced` DateTime DEFAULT toDateTime(0),
    `job_count`   Int32    DEFAULT -1      -- -1 = never synced
)
ENGINE = ReplacingMergeTree(last_synced)
ORDER BY (platform, slug)
