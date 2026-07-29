#!/usr/bin/env bash
# ============================================================================
# One command to run the whole system locally: ClickHouse, the browser sidecar,
# the master (CT ingest + queues + compactor + web) and both worker lanes.
#
#     ./dev.sh          start everything, tail the master log
#     ./dev.sh stop     stop everything
#     ./dev.sh status    what is running
#
# Then open http://localhost:4000/admin  (log in first, see below).
# ============================================================================
set -uo pipefail
cd "$(dirname "$0")"

LOG=/tmp/listsignal-dev
mkdir -p "$LOG"

# Dev-only env. Prod pins the resolver to local Unbound; a Mac has none, so
# point at a public resolver here. LS_ADMIN_EMAILS unlocks /admin.
export LS_DNS_SERVER=1.1.1.1
export LS_ADMIN_EMAILS=admin@listsignal.com
export MIX_ENV=dev

stop_all() {
  pkill -f "master@127.0.0.1"     2>/dev/null
  pkill -f "worker_disc@127.0.0.1"   2>/dev/null
  pkill -f "worker_enrich@127.0.0.1" 2>/dev/null
  pkill -f "browser_sidecar.py"   2>/dev/null
  echo "stopped (ClickHouse left running — it holds your data)"
}

status() {
  printf "%-22s %s\n" "clickhouse"  "$(curl -s -m 2 127.0.0.1:8123/ping 2>/dev/null || echo DOWN)"
  printf "%-22s %s\n" "browser sidecar" "$(curl -s -m 2 127.0.0.1:8900/health 2>/dev/null || echo DOWN)"
  for p in master@127.0.0.1 worker_disc@127.0.0.1 worker_enrich@127.0.0.1; do
    pgrep -f "$p" >/dev/null && printf "%-22s UP\n" "${p%%@*}" || printf "%-22s DOWN\n" "${p%%@*}"
  done
  printf "%-22s %s\n" "web" "$(curl -s -o /dev/null -w '%{http_code}' -m 3 http://localhost:4000/ 2>/dev/null)"
}

case "${1:-start}" in
  stop)   stop_all; exit 0 ;;
  status) status;   exit 0 ;;
esac

stop_all >/dev/null 2>&1
sleep 2

echo "1/5  ClickHouse"
bash .ch/start-local-ch.sh >/dev/null 2>&1
curl -s -m 3 127.0.0.1:8123/ping >/dev/null || { echo "   FAILED — is clickhouse installed?"; exit 1; }

echo "2/5  browser sidecar (camoufox, max 3 concurrent)"
if [ -x ~/.listsignal-browser/venv/bin/python ]; then
  LS_BROWSER_PORT=8900 nohup ~/.listsignal-browser/venv/bin/python \
    ../devops/listsignal/browser_sidecar.py > "$LOG/sidecar.log" 2>&1 &
  export LS_BROWSER_URL=http://127.0.0.1:8900
else
  echo "   (not installed — enrichment will run HTTP-only)"
fi

echo "3/5  master  — CT ingest + queues + compactor + web on :4000"
LS_ROLE=master LS_MODE=ctl_live PORT=4000 \
  nohup elixir --name master@127.0.0.1 --cookie dev_cookie -S mix phx.server \
  > "$LOG/master.log" 2>&1 &

# The master must own the queues before a worker asks for work.
for _ in $(seq 1 40); do
  curl -s -m 2 -o /dev/null http://localhost:4000/ && break
  sleep 2
done

echo "4/5  worker — discovery lane"
LS_ROLE=worker LS_LANES=discovery LS_MASTER=master@127.0.0.1 \
  LS_BATCH_SIZE=100 LS_HTTP_CONCURRENCY=20 LS_DNS_CONCURRENCY=50 \
  nohup elixir --name worker_disc@127.0.0.1 --cookie dev_cookie -S mix run --no-halt \
  > "$LOG/worker_disc.log" 2>&1 &

echo "5/5  worker — enrichment lane"
LS_ROLE=worker LS_LANES=enrichment LS_MASTER=master@127.0.0.1 \
  nohup elixir --name worker_enrich@127.0.0.1 --cookie dev_cookie -S mix run --no-halt \
  > "$LOG/worker_enrich.log" 2>&1 &

sleep 25
echo
status
cat <<'TXT'

  Dashboard : http://localhost:4000/admin      (tabs: 1 · Discovery / 2 · Enrichment)
  Log in    : http://localhost:4000/users/log-in   -> admin@listsignal.com
              then open http://localhost:4000/dev/mailbox and click the magic link

  Logs      : tail -f /tmp/listsignal-dev/{master,worker_disc,worker_enrich,sidecar}.log
  Stop      : ./dev.sh stop

TXT
