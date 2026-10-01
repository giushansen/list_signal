#!/usr/bin/env bash
# Data model v2 migration runbook (2026-10-01). See docs/data-model-standards.md.
#
# Usage:  025_data_model_v2.sh [--host HOST]      (prod: on the master, fleet stopped)
#
# What it does, in order:
#   1. preflight: refuses to run if businesses_v2 already exists or free disk < 40 GB
#   2. applies 025_data_model_v2.sql (new tables, catalog, new log columns, the
#      one-time transform of businesses, the biz_signal import, legacy aliases,
#      and the atomic RENAME TABLE at the end)
#   3. recreates every materialized view and view that referenced a renamed
#      table, from SHOW CREATE with the names substituted; drops the three
#      dead helper views (v_business_export, v_business_unified, tmp_pool)
#   4. prints row counts so the operator can compare before/after
#
# Nothing is dropped: the v1 product table stays as bak_businesses_v1 and
# biz_signal stays, for the owner to drop after validation.
set -euo pipefail

HOST="127.0.0.1"
MIN_FREE_GB=40
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --min-free-gb) MIN_FREE_GB="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 1;;
  esac
done
if command -v clickhouse-client >/dev/null 2>&1; then BIN="clickhouse-client"; else BIN="clickhouse client"; fi
CH="$BIN --host $HOST -d ls"
HERE="$(cd "$(dirname "$0")" && pwd)"
SQL="$HERE/025_data_model_v2.sql"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── 1. preflight ──────────────────────────────────────────────────────────
if [ "$($CH -q "SELECT count() FROM system.tables WHERE database='ls' AND name='businesses_v2'")" != "0" ]; then
  echo "businesses_v2 already exists: a previous run stopped half way. Inspect before retrying."; exit 1
fi
if [ "$($CH -q "SELECT count() FROM system.tables WHERE database='ls' AND name='enrich_log'")" != "0" ]; then
  echo "enrich_log already exists: the rename already happened."; exit 1
fi
# The web watchdog cron restarts a stopped master after 5 minutes. On the
# 2026-10-01 run it brought the v1 release back at 08:08, mid-rename, and 17
# minutes of inserts 404'd. The flag below silences it (see watchdog_web.sh).
if [ ! -e /run/listsignal_maintenance ]; then
  echo "touch /run/listsignal_maintenance, then systemctl stop listsignal@master, before running this"; exit 1
fi
if systemctl is-active --quiet listsignal@master; then
  echo "listsignal@master is still running: stop it first"; exit 1
fi
FREE_GB=$($CH -q "SELECT intDiv(free_space, 1073741824) FROM system.disks WHERE name='default'")
if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then echo "only ${FREE_GB}G free, need ${MIN_FREE_GB}G for the transform"; exit 1; fi
log "preflight ok (${FREE_GB}G free)"
BEFORE=$($CH -q "SELECT count() FROM businesses")
log "businesses rows before: $BEFORE"

# ── 2. the generated SQL ──────────────────────────────────────────────────
log "applying $SQL"
$CH --multiquery --max_execution_time=7200 < "$SQL"
log "sql applied"

# ── 2b. renames ───────────────────────────────────────────────────────────
exists() { [ "$($CH -q "SELECT count() FROM system.tables WHERE database='ls' AND name='$1'")" = "1" ]; }
while read -r old new; do
  if exists "$old" && ! exists "$new"; then $CH -q "RENAME TABLE $old TO $new" && log "renamed $old -> $new"; fi
done <<'PAIRS'
domains_history enrich_log
domains_current domains
biz_enrichment_log http_deep_log
biz_enrichment http_deep_state
biz_products shop_products
biz_collections shop_collections
biz_career hr_jobs
biz_contact http_contacts
biz_pricing http_deep_prices
biz_news news_items
biz_page_fetch http_deep_fetch_log
ctl_sightings ctl_log
verified_source_records verified_log
verification_domain_keys verified_keys
verification_runs verified_runs
verification_ch_accounts verified_ch_accounts
verification_inpi_ratios verified_inpi_ratios
PAIRS
$CH -q "RENAME TABLE businesses TO bak_businesses_v1, businesses_v2 TO businesses"
log "product table swapped (v1 kept as bak_businesses_v1)"

# ── 3. views ──────────────────────────────────────────────────────────────
substitute() {
  sed -e 's/ls\.domains_history\b/ls.enrich_log/g' \
      -e 's/ls\.domains_current\b/ls.domains/g' \
      -e 's/ls\.biz_enrichment_log\b/ls.http_deep_log/g' \
      -e 's/ls\.biz_enrichment\b/ls.http_deep_state/g' \
      -e 's/ls\.biz_products\b/ls.shop_products/g' \
      -e 's/ls\.biz_collections\b/ls.shop_collections/g' \
      -e 's/ls\.biz_career\b/ls.hr_jobs/g' \
      -e 's/ls\.biz_contact\b/ls.http_contacts/g' \
      -e 's/ls\.biz_pricing\b/ls.http_deep_prices/g' \
      -e 's/ls\.biz_news\b/ls.news_items/g' \
      -e 's/ls\.biz_page_fetch\b/ls.http_deep_fetch_log/g' \
      -e 's/ls\.ctl_sightings\b/ls.ctl_log/g' \
      -e 's/ls\.verified_source_records\b/ls.verified_log/g' \
      -e 's/ls\.verification_domain_keys\b/ls.verified_keys/g' \
      -e 's/ls\.verification_runs\b/ls.verified_runs/g' \
      -e 's/ls\.mv_domains_current\b/ls.mv_domains/g'
}

for dead in v_business_export v_business_unified tmp_pool; do
  $CH -q "DROP VIEW IF EXISTS $dead" && log "dropped view $dead"
done

VIEWS=$($CH -q "SELECT name FROM system.tables WHERE database='ls' AND engine IN ('MaterializedView','View') AND (create_table_query LIKE '%domains_history%' OR create_table_query LIKE '%domains_current%' OR create_table_query LIKE '%biz_%' OR create_table_query LIKE '%ctl_sightings%' OR create_table_query LIKE '%verified_source_records%' OR create_table_query LIKE '%verification_%') FORMAT TSV")
for v in $VIEWS; do
  # TSVRaw: the default TSV output escapes quotes and newlines in the
  # statement, which broke on mv_daily_blocked's '' literal in the prod run
  # (the six views were then recreated by hand from clickhouse/schema.sql).
  create=$($CH --format=TSVRaw -q "SHOW CREATE TABLE $v" | substitute)
  newname=$(echo "$v" | sed 's/^mv_domains_current$/mv_domains/')
  $CH -q "DROP TABLE IF EXISTS $v"
  echo "$create" | $CH --multiquery
  log "recreated view $v as $newname"
done

# ── 4. report ─────────────────────────────────────────────────────────────
log "businesses rows after: $($CH -q "SELECT count() FROM businesses") (before: $BEFORE)"
log "changes_log rows: $($CH -q "SELECT count() FROM changes_log")"
log "tech_catalog rows: $($CH -q "SELECT count() FROM tech_catalog")"
log "http_tech non-empty: $($CH -q "SELECT countIf(notEmpty(http_tech)) FROM businesses")"
log "done. Deploy the v2 release now, then rm /run/listsignal_maintenance; drop bak_businesses_v1 and biz_signal after validation."
