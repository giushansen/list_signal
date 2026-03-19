#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

echo "🔧 ListSignal ClickHouse Setup (v2 — Distributed)"

# Detect client binary
if command -v clickhouse-client &>/dev/null; then
    CH="clickhouse-client"
else
    CH="clickhouse client"
fi

# Ensure ClickHouse is running
if [[ "$(uname)" == "Darwin" ]]; then
    if ! $CH --query "SELECT 1" &>/dev/null 2>&1; then
        echo "Starting ClickHouse..."
        nohup clickhouse server >/dev/null 2>&1 &
        sleep 3
    fi
else
    sudo systemctl start clickhouse-server 2>/dev/null || true
    sleep 2
fi

$CH --query "SELECT version()" &>/dev/null || { echo -e "${RED}✗ ClickHouse not responding${NC}"; exit 1; }
echo -e "${GREEN}✓${NC} ClickHouse $($CH --query 'SELECT version()')"

$CH < "$SCRIPT_DIR/schema.sql"
echo -e "${GREEN}✓${NC} Schema created"

$CH --database=ls --query "SHOW TABLES FORMAT Pretty"

echo ""
echo -e "${GREEN}✅ Ready. Enrichment inserts go to ls.enrichments${NC}"
echo -e "   Latest state auto-maintained in ls.domains_current"
