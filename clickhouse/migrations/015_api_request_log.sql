-- 015: full audit trail of API/MCP usage (who, when, how, what was read).
-- Append-only, one row per successful call, written async off the request
-- path. Metabase reads this directly; Umami keeps the event-level pulse.
CREATE TABLE IF NOT EXISTS api_request_log
(
    ts           DateTime DEFAULT now(),
    user_id      String,
    email        String,
    plan         LowCardinality(String),
    key_prefix   String,
    surface      LowCardinality(String),  -- 'rest' | 'mcp'
    endpoint     LowCardinality(String),  -- 'company' | 'search' | ... | tool name
    target       String,                  -- domain looked up ('' for search)
    filters      String,                  -- JSON of accepted search filters
    result_count UInt32 DEFAULT 0
)
ENGINE = MergeTree
ORDER BY (ts)
TTL ts + INTERVAL 2 YEAR;
