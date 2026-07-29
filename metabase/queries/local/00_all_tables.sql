-- EVERY TABLE at a glance: rows, size, engine, and which pipeline owns it.
-- Start here — one query that tells you the shape of the whole database.
SELECT
    name AS table,
    multiIf(
      name IN ('domains_history','enrichments','domains_current','domains_fast','mv_domains_current'),
        '1 · discovery',
      name LIKE 'biz_%', '2 · enrichment',
      name = 'businesses', '★ product',
      name LIKE 'daily_%' OR name LIKE 'mv_daily%', 'analytics',
      'other') AS owner,
    engine,
    formatReadableQuantity(total_rows) AS rows,
    formatReadableSize(total_bytes)    AS size
FROM system.tables
WHERE database = 'ls'
ORDER BY owner, total_bytes DESC NULLS LAST
