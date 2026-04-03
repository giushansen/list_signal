#!/bin/bash
# ============================================================================
# ListSignal ClickHouse Setup — Clean install
# Nukes existing database and creates fresh schema.
# Run: bash clickhouse/setup.sh
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "ListSignal ClickHouse Setup"
echo ""

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

$CH --query "SELECT version()" &>/dev/null || { echo -e "${RED}ClickHouse not responding${NC}"; exit 1; }
echo -e "${GREEN}OK${NC} ClickHouse $($CH --query 'SELECT version()')"

# Nuke existing
echo -e "${YELLOW}Dropping existing database...${NC}"
$CH --query "DROP DATABASE IF EXISTS ls"
echo -e "${GREEN}OK${NC} Old database dropped"

# Create fresh from schema.sql (single source of truth)
$CH < "$SCRIPT_DIR/schema.sql"
echo -e "${GREEN}OK${NC} Schema created"

# Verify
echo ""
echo "Tables:"
$CH --database=ls --query "SHOW TABLES FORMAT Pretty"
echo ""
ECOLS=$($CH --database=ls --query "SELECT count() FROM system.columns WHERE database = 'ls' AND table = 'enrichments'")
DCOLS=$($CH --database=ls --query "SELECT count() FROM system.columns WHERE database = 'ls' AND table = 'domains_current'")
echo "enrichments columns: ${ECOLS}"
echo "domains_current columns: ${DCOLS}"

echo ""
echo -e "${GREEN}Ready.${NC}"
echo "  Pipeline inserts go to ls.enrichments"
echo "  Latest state auto-maintained in ls.domains_current"
echo "  Both tables have ${ECOLS} columns."
echo ""
echo "Next steps:"
echo "  1. make dev          # start master (CTL + queue + dashboard)"
echo "  2. make dev-worker   # start worker (connects to master, runs pipeline)"
