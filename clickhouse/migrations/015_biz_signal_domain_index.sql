-- biz_signal: bloom-filter skip index on domain (2026-08-24)
--
-- biz_signal is ORDER BY (kind, value, domain, changed_at) because the money
-- query is "who removed Klaviyo last month" — kind+value first. But the most
-- FREQUENT query is the opposite shape: every store page asks
-- "what changed for THIS domain", 45,334 times a day. `domain` is the third
-- sort-key column, so it cannot prune, and each lookup scanned 3,236,776 rows
-- / 115 MB — about 5.2 TB of reads a day for what should be point lookups.
--
-- A bloom filter is the right tool and it is SAFE for correctness: it can
-- produce false POSITIVES (occasionally reading a granule that turns out not
-- to hold the domain — merely a little slower) but never false NEGATIVES, so
-- no row can ever be missed. Results stay byte-identical; only the number of
-- granules read changes.
--
-- Cost is small: the table is 79 MiB across 3.2M rows, so the index is a few
-- MB. 0.01 is the standard false-positive rate; GRANULARITY 1 evaluates it per
-- granule, which is what makes the skipping fine-grained.
ALTER TABLE ls.biz_signal
    ADD INDEX IF NOT EXISTS idx_biz_signal_domain domain TYPE bloom_filter(0.01) GRANULARITY 1;

ALTER TABLE ls.biz_signal MATERIALIZE INDEX idx_biz_signal_domain;
