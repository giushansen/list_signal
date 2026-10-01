#!/usr/bin/env bash
# 026: crawl gate, conditional-GET validators, text fingerprint, realness
# score (2026-10-01). Online: ADD COLUMN only, plus two background
# mutations on businesses. The app keeps running; run this BEFORE the
# release that writes the new columns is deployed (an older release
# ignores them, a newer one fails its inserts without them).
#
#   bash 026_crawl_gate_realness.sh [--sql /root/026_crawl_gate_realness.sql]
#
# The two UPDATE mutations rewrite the affected columns of every part of
# businesses (8.6 GB); they run in the background and ClickHouse reports
# them in system.mutations. The realness UPDATE reads 15 columns, so give
# it off-peak time and watch disk (it needs the size of those columns as
# temporary space).
set -euo pipefail
SQL=/root/026_crawl_gate_realness.sql
while [ $# -gt 0 ]; do
  case "$1" in
    --sql) SQL="$2"; shift 2;;
    *) echo "unknown arg $1"; exit 2;;
  esac
done
CH="clickhouse-client --database=ls"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

[ -f "$SQL" ] || { echo "missing $SQL"; exit 1; }
[ -e /run/listsignal_maintenance ] && echo "note: maintenance flag is set; this migration does not need the app stopped"

log "businesses rows: $($CH -q 'SELECT count() FROM businesses')"
log "parked before: $($CH -q "SELECT countIf(estimated_junk = 'parked') FROM businesses")"
log "applying $SQL"
$CH --multiquery < "$SQL"
log "applied; mutations pending: $($CH -q "SELECT count() FROM system.mutations WHERE table = 'businesses' AND NOT is_done")"
log "watch: clickhouse-client -q \"SELECT command, is_done, parts_to_do FROM system.mutations WHERE table='businesses' ORDER BY create_time DESC LIMIT 3\""
log "after the mutations: SELECT countIf(estimated_junk = 'parked'), round(avg(estimated_realness), 3), countIf(estimated_realness >= 0.6) FROM businesses"
