#!/usr/bin/env bash
# Re-dump the live production schema into clickhouse/schema.sql so the file in
# git always matches reality. Run after any migration.
#
#     bash clickhouse/dump_schema.sh > clickhouse/schema.sql
#
# The header is emitted here rather than hand-written into schema.sql, because
# a hand-written header is silently destroyed by the very command documented
# above — which is how the previous header ended up citing two scripts that do
# not exist.
set -euo pipefail

HOST="${LS_CH_HOST:-root@45.63.7.58}"

cat <<HEADER
-- ═══════════════════════════════════════════════════════════════════════════
-- ListSignal ClickHouse schema — AUTHORITATIVE, generated from production.
--
--   Regenerate:  bash clickhouse/dump_schema.sh > clickhouse/schema.sql
--   Last dumped: $(date -u +%Y-%m-%d)
--   Source:      $HOST
--
-- Read docs/data-model-standards.md for the naming rules and
-- docs/architecture.md for how the tables fit together. In short:
--
--   LOGS (append-only)       enrich_log ──MV──> domains ──view──> domains_fast
--                            http_deep_log · ctl_log · verified_log · http_pages
--                            plus the persistent \`platforms\` registry
--   CURRENT STATE            http_deep_state · http_contacts · hr_jobs
--                            · http_deep_prices · shop_products · shop_collections
--                            · news_items · tech_catalog
--   COMPACTED PRODUCT        businesses          (folded every 5 min)
--   CHANGES                  changes_log         (one row per change of a tracked column)
--   ANALYTICS                daily_* + their mv_daily_* triggers
--
-- This file DOCUMENTS the live schema; it is not applied on deploy. Pending
-- changes live in clickhouse/migrations/ and are applied during a deploy
-- window, then dumped back here. If a migration listed there is absent from
-- this dump, it has not been applied to production yet.
--
-- Views are dumped too. bak_* tables are migration safety copies awaiting the
-- owner's drop decision.
-- ═══════════════════════════════════════════════════════════════════════════

HEADER

# shellcheck disable=SC2029
ssh "$HOST" 'for t in $(clickhouse-client --query "SELECT name FROM system.tables WHERE database='"'"'ls'"'"' AND name NOT LIKE '"'"'.inner%'"'"' ORDER BY engine, name FORMAT TSV"); do
  echo "-- ═══ $t ═══"
  clickhouse-client --query "SHOW CREATE TABLE ls.$t" --format=TSVRaw | sed "s/\\\\n/\n/g"
  echo ";"; echo
done'
