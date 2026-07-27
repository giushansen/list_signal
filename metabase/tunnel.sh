#!/usr/bin/env bash
# SSH tunnel: laptop 127.0.0.1:8123 -> prod master ClickHouse (which is
# localhost-only on the box — never expose it publicly).
# Metabase (in Docker) reaches this via host.docker.internal:8123.
#
# Usage:
#   ./tunnel.sh           # foreground (Ctrl-C to stop)
#   ./tunnel.sh -f        # background (kill with: pkill -f 'ssh.*8123:127.0.0.1:8123')
set -euo pipefail

MASTER=root@45.63.7.58
BG=""
[[ "${1:-}" == "-f" ]] && BG="-f"

exec ssh -N $BG \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -L 127.0.0.1:8123:127.0.0.1:8123 \
  "$MASTER"
