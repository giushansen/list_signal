#!/bin/bash
# ============================================================================
# ListSignal ClickHouse Setup — Clean install
# Nukes existing database and creates fresh schema.
# Run: bash clickhouse/setup.sh
# ============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo "🔧 ListSignal ClickHouse Setup"
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

$CH --query "SELECT version()" &>/dev/null || { echo -e "${RED}✗ ClickHouse not responding${NC}"; exit 1; }
echo -e "${GREEN}✓${NC} ClickHouse $($CH --query 'SELECT version()')"

# Nuke existing
echo -e "${YELLOW}Dropping existing database...${NC}"
$CH --query "DROP DATABASE IF EXISTS ls"
echo -e "${GREEN}✓${NC} Old database dropped"

# Create fresh
$CH < "$SCRIPT_DIR/schema.sql"
echo -e "${GREEN}✓${NC} Schema created (43 columns)"

# Verify
echo ""
echo "Tables:"
$CH --database=ls --query "SHOW TABLES FORMAT Pretty"
echo ""
echo "Enrichments columns: $($CH --database=ls --query 'SELECT count() FROM system.columns WHERE database = '\''ls'\'' AND table = '\''enrichments'\''')"
echo "domains_current columns: $($CH --database=ls --query 'SELECT count() FROM system.columns WHERE database = '\''ls'\'' AND table = '\''domains_current'\''')"

echo ""
echo -e "${GREEN}✅ Ready. Pipeline inserts go to ls.enrichments${NC}"
echo -e "   Latest state auto-maintained in ls.domains_current"
echo -e "   Both tables have all 43 columns."