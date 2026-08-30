-- Master memory forensics (2026-08-30): a black-box recorder for the
-- recurring watchdog-restart investigation. :erlang.memory() only sees what
-- the BEAM heap allocator tracks; measured live on 2026-08-30 there is a
-- ~1.37GB gap between the cgroup's view of RSS and what Erlang reports —
-- almost certainly the EXLA/XLA native runtime backing the ML classifier,
-- which BEAM instrumentation cannot see at all. Periodic snapshots (written
-- by LS.Ops.MemoryForensics) mean the NEXT crash has an actual trail to read
-- instead of another guess. Denormalized JSON columns are deliberate: this
-- table is for a human reading `SELECT * ... ORDER BY at DESC LIMIT 20`
-- during an incident, not for structured queries.
CREATE TABLE IF NOT EXISTS ls.ops_memory_snapshots
(
    `node`             LowCardinality(String),
    `at`               DateTime,
    `self_rss_mb`      UInt32,   -- /proc/self/status VmRSS: what the OS/cgroup actually charges this process
    `erlang_total_mb`  UInt32,   -- :erlang.memory()[:total]: what BEAM's own allocator tracks
    `native_gap_mb`    Int32,    -- self_rss_mb - erlang_total_mb: memory BEAM cannot see at all
    `processes_mb`     UInt32,
    `ets_mb`            UInt32,
    `binary_mb`        UInt32,
    `top_ets`          String,   -- JSON [{name, mb, rows}], largest first
    `top_processes`    String,   -- JSON [{name, mb, mailbox, initial_call}], largest first
    `alarm`            UInt8     -- 1 when this snapshot crossed the danger threshold (extra detail, off-cycle)
)
ENGINE = MergeTree
ORDER BY (node, at)
TTL at + INTERVAL 14 DAY
SETTINGS index_granularity = 8192;
