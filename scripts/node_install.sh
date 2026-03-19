#!/bin/bash
# ============================================================================
# LISTSIGNAL NODE SETUP
# ============================================================================
# Usage:
#   bash scripts/node_install.sh
#
# Then start as:
#   MASTER:  KEYBLOC_ROLE=master KEYBLOC_MODE=ctl_live \
#            iex --name master@10.0.0.1 --cookie ls_prod -S mix
#
#   WORKER:  KEYBLOC_ROLE=worker KEYBLOC_MASTER=master@10.0.0.1 \
#            iex --name worker_tok@10.0.0.2 --cookie ls_prod -S mix
# ============================================================================

set -euo pipefail
GREEN='\033[0;32m'; NC='\033[0m'

echo "🔧 ListSignal Node Setup"

apt-get update -qq
apt-get install -y git curl wget tmux htop iftop build-essential autoconf \
    libncurses5-dev libssl-dev unzip rsync unbound wireguard

# Limits
cat >> /etc/security/limits.conf <<EOF
root soft nofile 65536
root hard nofile 65536
EOF

# Swap
if [[ ! -f /swapfile2 ]]; then
    fallocate -l 4G /swapfile2 && chmod 600 /swapfile2
    mkswap /swapfile2 && swapon /swapfile2
    echo '/swapfile2 none swap sw 0 0' >> /etc/fstab
fi

# Unbound
cat > /etc/unbound/unbound.conf.d/local.conf << 'UNBOUND'
server:
    interface: 127.0.0.1
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes
    access-control: 127.0.0.0/8 allow
    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes
    prefetch: yes
    num-threads: 1
    num-queries-per-thread: 256
    verbosity: 1
    logfile: ""
UNBOUND
unbound-checkconf && systemctl enable unbound && systemctl restart unbound
rm -f /etc/resolv.conf && echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Erlang + Elixir
if [ ! -d ~/.asdf ]; then
    git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.1
fi
. ~/.asdf/asdf.sh
grep -q asdf ~/.bashrc || echo '. ~/.asdf/asdf.sh' >> ~/.bashrc
asdf plugin add erlang 2>/dev/null || true
asdf install erlang 27.0 && asdf global erlang 27.0
asdf plugin add elixir 2>/dev/null || true
asdf install elixir 1.18.4 && asdf global elixir 1.18.4

# Project
cd /root
if [ -d list_signal ]; then
    cd list_signal && git pull --rebase
else
    git clone https://github.com/YOUR_USER/list_signal.git
    cd list_signal
fi
. ~/.asdf/asdf.sh
mix local.hex --force && mix local.rebar --force
mix deps.get && mix compile
mkdir -p input output

echo -e "${GREEN}✅ Node ready. See DISTRIBUTED.md for startup commands.${NC}"
