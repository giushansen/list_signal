#!/usr/bin/env bash
# Bootstrap Metabase for ListSignal: initial admin setup (if fresh), the
# ClickHouse connection, the "ListSignal Health" collection, one native
# question per queries/*.sql, and a dashboard holding them all.
#
# Idempotent-ish: safe to re-run; it skips setup if done and re-creates
# questions only if the collection is missing.
#
# Requires: curl, jq, a running Metabase on $MB_URL, tunnel up on :8123.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
MB_URL="${MB_URL:-http://localhost:3000}"
source "$DIR/.env.local"

api() { # api METHOD PATH [JSON]
  local m="$1" p="$2" d="${3:-}"
  if [[ -n "$d" ]]; then
    curl -s -X "$m" "$MB_URL/api$p" -H "Content-Type: application/json" \
      ${SESSION:+-H "X-Metabase-Session: $SESSION"} -d "$d"
  else
    curl -s -X "$m" "$MB_URL/api$p" -H "Content-Type: application/json" \
      ${SESSION:+-H "X-Metabase-Session: $SESSION"}
  fi
}

echo "── waiting for Metabase at $MB_URL ..."
for i in $(seq 1 60); do
  curl -s "$MB_URL/api/health" | grep -q '"ok"' && break
  sleep 5
  [[ $i == 60 ]] && { echo "Metabase never came up"; exit 1; }
done
echo "   up."

# ── 1. Initial setup or login ────────────────────────────────────────────────
SETUP_TOKEN=$(curl -s "$MB_URL/api/session/properties" | jq -r '.["setup-token"] // empty')
if [[ -n "$SETUP_TOKEN" ]]; then
  echo "── fresh instance: running initial setup"
  SESSION=$(api POST /setup "$(jq -n \
    --arg tok "$SETUP_TOKEN" --arg em "$MB_ADMIN_EMAIL" --arg pw "$MB_ADMIN_PASSWORD" \
    '{token:$tok,
      user:{email:$em, password:$pw, first_name:"Will", last_name:"K", site_name:"ListSignal"},
      prefs:{site_name:"ListSignal", allow_tracking:false}}')" | jq -r '.id // empty')
  [[ -z "$SESSION" ]] && { echo "setup failed"; exit 1; }
else
  echo "── already set up: logging in"
  SESSION=$(api POST /session "$(jq -n --arg em "$MB_ADMIN_EMAIL" --arg pw "$MB_ADMIN_PASSWORD" \
    '{username:$em, password:$pw}')" | jq -r '.id // empty')
  [[ -z "$SESSION" ]] && { echo "login failed"; exit 1; }
fi
echo "   session ok."

# ── 2. ClickHouse database connection ───────────────────────────────────────
DB_ID=$(api GET /database | jq -r '.data[] | select(.name=="ListSignal ClickHouse (prod, read-only)") | .id' | head -1)
if [[ -z "$DB_ID" ]]; then
  echo "── adding ClickHouse connection"
  DB_ID=$(api POST /database "$(jq -n --arg pw "$CH_METABASE_PASSWORD" --arg u "$CH_METABASE_USER" \
    '{name:"ListSignal ClickHouse (prod, read-only)", engine:"clickhouse",
      details:{host:"host.docker.internal", port:8123, user:$u, password:$pw,
               dbname:"ls", db:"ls", ssl:false, "tunnel-enabled":false}}')" | jq -r '.id // empty')
  [[ -z "$DB_ID" ]] && { echo "failed to add database — is the clickhouse driver present?"; exit 1; }
else
  echo "── ClickHouse connection exists (id $DB_ID)"
fi
echo "   database id: $DB_ID"

# ── 3. Collection ───────────────────────────────────────────────────────────
COLL_ID=$(api GET /collection | jq -r '.[] | select(.name=="ListSignal Health") | .id' | head -1)
if [[ -z "$COLL_ID" ]]; then
  COLL_ID=$(api POST /collection '{"name":"ListSignal Health","description":"Prod data health: discovery volume, worker health, silent pipeline failures"}' | jq -r '.id')
fi
echo "── collection id: $COLL_ID"

# ── 4. Questions from queries/*.sql ─────────────────────────────────────────
declare -a CARD_IDS=()
make_card() { # make_card NAME FILE DISPLAY VIZ_JSON
  local name="$1" file="$2" display="$3" viz="$4"
  local sql; sql=$(cat "$DIR/queries/$file")
  local id
  id=$(api POST /card "$(jq -n \
    --arg name "$name" --arg sql "$sql" --arg display "$display" \
    --argjson db "$DB_ID" --argjson coll "$COLL_ID" --argjson viz "$viz" \
    '{name:$name, display:$display, visualization_settings:$viz, collection_id:$coll,
      dataset_query:{type:"native", database:$db, native:{query:$sql}}}')" | jq -r '.id // empty')
  [[ -z "$id" ]] && { echo "   FAILED: $name"; return 1; }
  echo "   card $id: $name"
  CARD_IDS+=("$id")
}

echo "── creating questions"
make_card "01 · Discovery counts (24h)"            01_discovery_counts_24h.sql        table '{}'
make_card "02 · New SaaS (24h)"                    02_saas_last_24h.sql               table '{}'
make_card "03 · New Shopify stores (24h)"          03_shopify_last_24h.sql            table '{}'
make_card "04 · Hourly throughput (7d)"            04_hourly_throughput_7d.sql        line  '{"graph.dimensions":["hour"],"graph.metrics":["enriched","shopify","saas"]}'
make_card "05 · Worker throughput + stage health (24h)" 05_worker_throughput_24h.sql  table '{}'
make_card "06 · HTTP status mix (24h vs prev)"     06_http_status_mix_24h_vs_prev.sql table '{}'
make_card "07 · Crawler errors (24h)"              07_http_errors_24h.sql             table '{}'
make_card "08 · Stage failure ratios (48h)"        08_stage_failure_ratios_48h.sql    line  '{"graph.dimensions":["hour"],"graph.metrics":["dns_empty","http_no_response","http_error_rate","http_5xx","unclassified","rdap_errors","bgp_empty"]}'
make_card "09 · Business model mix (24h vs prev)"  09_business_model_mix_24h_vs_prev.sql table '{}'
make_card "10 · Pipeline freshness"                10_pipeline_freshness.sql          table '{}'
make_card "11 · Good domains daily (real businesses)" 11_good_domains_daily.sql       line  '{"graph.dimensions":["day"],"graph.metrics":["good_domains","good_with_tranco"]}'
make_card "12 · Bad / suspicious domains daily"    12_bad_domains_daily.sql           line  '{"graph.dimensions":["day"],"graph.metrics":["flagged_malware","flagged_phishing","dead_dns","parked_hint"]}'
make_card "13 · Blacklist candidates (junk repeaters)" 13_blacklist_candidates.sql    table '{}'
make_card "14 · Crawl gap on legit domains daily"  14_crawl_gap_daily.sql             line  '{"graph.dimensions":["day"],"graph.metrics":["crawl_ok","rate_limited","waf_blocked","need_better_crawler_pct"]}'
make_card "15 · Duplicate churn daily (exact)"     15_duplicate_churn_daily.sql       line  '{"graph.dimensions":["day"],"graph.metrics":["dupe_rows","dupe_pct"]}'

# ── 5. Dashboard ────────────────────────────────────────────────────────────
DASH_ID=$(api GET "/collection/$COLL_ID/items" | jq -r '.data[]? | select(.model=="dashboard" and .name=="ListSignal Health") | .id' | head -1)
if [[ -z "$DASH_ID" ]]; then
  DASH_ID=$(api POST /dashboard "$(jq -n --argjson coll "$COLL_ID" \
    '{name:"ListSignal Health", collection_id:$coll,
      description:"Daily check: is the pipeline alive, is the data sane, is anything failing silently?"}')" | jq -r '.id')
fi
echo "── dashboard id: $DASH_ID"

# Layout: 24-col grid. freshness+counts up top, trends, then workers/errors, then lists.
DASHCARDS=$(jq -n \
  --argjson c0 "${CARD_IDS[0]}" --argjson c1 "${CARD_IDS[1]}" --argjson c2 "${CARD_IDS[2]}" \
  --argjson c3 "${CARD_IDS[3]}" --argjson c4 "${CARD_IDS[4]}" --argjson c5 "${CARD_IDS[5]}" \
  --argjson c6 "${CARD_IDS[6]}" --argjson c7 "${CARD_IDS[7]}" --argjson c8 "${CARD_IDS[8]}" \
  --argjson c9 "${CARD_IDS[9]}" \
  '{dashcards: [
    {id:-1,  card_id:$c9, row:0,  col:0,  size_x:12, size_y:4},
    {id:-2,  card_id:$c0, row:0,  col:12, size_x:12, size_y:4},
    {id:-3,  card_id:$c3, row:4,  col:0,  size_x:24, size_y:7},
    {id:-4,  card_id:$c7, row:11, col:0,  size_x:24, size_y:7},
    {id:-5,  card_id:$c4, row:18, col:0,  size_x:24, size_y:5},
    {id:-6,  card_id:$c5, row:23, col:0,  size_x:12, size_y:5},
    {id:-7,  card_id:$c8, row:23, col:12, size_x:12, size_y:5},
    {id:-8,  card_id:$c6, row:28, col:0,  size_x:24, size_y:6},
    {id:-9,  card_id:$c1, row:34, col:0,  size_x:24, size_y:8},
    {id:-10, card_id:$c2, row:42, col:0,  size_x:24, size_y:8}
  ]}')
RES=$(api PUT "/dashboard/$DASH_ID" "$DASHCARDS" | jq -r 'if .dashcards then "ok (\(.dashcards|length) cards)" else . end' | head -3)
echo "── dashboard layout: $RES"
echo
echo "DONE → $MB_URL/dashboard/$DASH_ID"
