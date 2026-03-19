#!/bin/bash
# ============================================================================
# KEYBLOC WIREGUARD SETUP
# ============================================================================
# Sets up encrypted mesh network for Erlang distribution across regions.
#
# Nodes:
#   10.0.0.1 — master  (NY)     140.82.42.208
#   10.0.0.2 — tok     (Tokyo)  139.180.197.75
#   10.0.0.3 — syd     (Sydney) 108.61.212.155
#   10.0.0.4 — sg      (SG)     100.78.235.42
#
# Usage:
#   bash scripts/wireguard_setup.sh master   # on NY node
#   bash scripts/wireguard_setup.sh tok      # on Tokyo node
#   bash scripts/wireguard_setup.sh syd      # on Sydney node
#   bash scripts/wireguard_setup.sh sg       # on SG node
#
# After setup on all nodes:
#   wg-quick up wg0
#   ping 10.0.0.1   # test from any node
# ============================================================================

set -euo pipefail

NODE="${1:-}"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'

if [[ -z "$NODE" ]]; then
    echo "Usage: $0 <master|tok|syd|sg>"
    echo ""
    echo "Run on each node to generate WireGuard config."
    echo "Then share public keys between nodes."
    exit 1
fi

# Install WireGuard
if ! command -v wg &>/dev/null; then
    echo "Installing WireGuard..."
    if [[ "$(uname)" == "Darwin" ]]; then
        brew install wireguard-tools
    else
        apt-get update -qq && apt-get install -y wireguard
    fi
fi

# Generate keys if not exist
WG_DIR="/etc/wireguard"
sudo mkdir -p "$WG_DIR"

if [[ ! -f "$WG_DIR/privatekey" ]]; then
    wg genkey | sudo tee "$WG_DIR/privatekey" > /dev/null
    sudo chmod 600 "$WG_DIR/privatekey"
    sudo cat "$WG_DIR/privatekey" | wg pubkey | sudo tee "$WG_DIR/publickey" > /dev/null
    echo -e "${GREEN}✓${NC} Generated WireGuard keys"
fi

PRIVATE_KEY=$(sudo cat "$WG_DIR/privatekey")
PUBLIC_KEY=$(sudo cat "$WG_DIR/publickey")

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Node: $NODE${NC}"
echo -e "${YELLOW}  Public Key: $PUBLIC_KEY${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
echo ""
echo "Share this public key with all other nodes."
echo "Then fill in the peer public keys below and re-run."
echo ""

# Node configuration
declare -A WG_IPS=(
    [master]="10.0.0.1"
    [tok]="10.0.0.2"
    [syd]="10.0.0.3"
    [sg]="10.0.0.4"
)

declare -A ENDPOINTS=(
    [master]="140.82.42.208:51820"
    [tok]="139.180.197.75:51820"
    [syd]="108.61.212.155:51820"
    [sg]="100.78.235.42:51820"
)

# ============================================================================
# FILL IN PUBLIC KEYS AFTER RUNNING ON EACH NODE
# ============================================================================
declare -A PUBKEYS=(
    [master]="REPLACE_WITH_MASTER_PUBKEY"
    [tok]="REPLACE_WITH_TOK_PUBKEY"
    [syd]="REPLACE_WITH_SYD_PUBKEY"
    [sg]="REPLACE_WITH_SG_PUBKEY"
)

MY_IP="${WG_IPS[$NODE]}"

# Generate config
CONFIG="[Interface]
Address = ${MY_IP}/24
PrivateKey = ${PRIVATE_KEY}
ListenPort = 51820
"

for PEER in master tok syd sg; do
    [[ "$PEER" == "$NODE" ]] && continue

    PEER_PUBKEY="${PUBKEYS[$PEER]}"
    PEER_IP="${WG_IPS[$PEER]}"
    PEER_ENDPOINT="${ENDPOINTS[$PEER]}"

    CONFIG+="
[Peer]
# ${PEER}
PublicKey = ${PEER_PUBKEY}
AllowedIPs = ${PEER_IP}/32
Endpoint = ${PEER_ENDPOINT}
PersistentKeepalive = 25
"
done

echo "$CONFIG" | sudo tee "$WG_DIR/wg0.conf" > /dev/null
sudo chmod 600 "$WG_DIR/wg0.conf"

echo -e "${GREEN}✓${NC} Config written to $WG_DIR/wg0.conf"
echo ""

if [[ "${PUBKEYS[master]}" == "REPLACE_WITH_"* ]]; then
    echo -e "${RED}⚠  Public keys not filled in yet!${NC}"
    echo "  1. Run this script on ALL nodes"
    echo "  2. Collect public keys from each node"
    echo "  3. Edit PUBKEYS array in this script"
    echo "  4. Re-run on ALL nodes"
    echo "  5. Then: sudo wg-quick up wg0"
else
    echo "Ready to activate:"
    echo "  sudo wg-quick up wg0"
    echo "  sudo systemctl enable wg-quick@wg0  # auto-start on boot"
    echo ""
    echo "Test: ping ${WG_IPS[master]}"
fi

# Open firewall port
if command -v ufw &>/dev/null; then
    sudo ufw allow 51820/udp 2>/dev/null || true
    echo -e "${GREEN}✓${NC} UFW: port 51820/udp allowed"
fi
