# ListSignal

Domain intelligence platform. Ingests SSL certificates in real-time, enriches domains with DNS/HTTP/BGP data, scores them for sales targeting, stores everything in ClickHouse.

No files in the pipeline. CTL → ETS queue → workers → ClickHouse. That's it.

## How it works

The master node polls Certificate Transparency logs and discovers new domains as SSL certificates are issued globally (~180 domains/sec, ~15M/day). Each new domain gets queued in an ETS table on the master. Worker nodes across the globe pull batches of 1000 domains, run them through DNS, HTTP, and BGP enrichment, and return a single enriched row per domain back to the master. The master batches these rows and inserts them into ClickHouse.

```
Master (NY)                              Workers (Tokyo/Sydney/SG)
                                         
CTL Poller ──→ ETS Queue (5M cap)        WorkerAgent pulls 1000 domains
                    │                         │
                    │  Erlang distribution     ├─ DNS   (resolver, scorer)
                    │  over WireGuard          ├─ HTTP  (client, tech detect, filter)
                    │                         ├─ BGP   (Team Cymru, scorer)
                    │                         │
                    ◄─────────────────────────┘ enriched rows
                    │
              Inserter (batch 5000 rows)
                    │
              ClickHouse
                ├─ enrichments (append-only, partitioned monthly)
                └─ domains_current (materialized view, latest per domain)
```

## Prerequisites

- Elixir 1.18+ / Erlang 27+
- ClickHouse (master node only)
- Unbound DNS resolver (worker nodes, `apt install unbound`)

## Setup

```bash
cd ~/Projects/list_signal

# Install deps and build assets
mix setup

# Compile
mix compile

# Setup ClickHouse (master only)
bash clickhouse/setup.sh
```

## Local development

Two iTerm tabs. No WireGuard needed — everything runs on localhost.

**Tab 1 — Master** (CTL poller + queue + ClickHouse inserter + dashboard):

```bash
LS_ROLE=master LS_MODE=ctl_live \
  iex --name master@127.0.0.1 --cookie dev_cookie -S mix phx.server
```

Dashboard at [http://localhost:4000](http://localhost:4000). Shows queue depth, worker status, insert rate.

**Tab 2 — Worker** (connects to master, enriches domains):

```bash
LS_ROLE=worker LS_MASTER=master@127.0.0.1 LS_HTTP_CONCURRENCY=20 \
  iex --name worker_dev@127.0.0.1 --cookie dev_cookie -S mix
```

Low concurrency (20) because you're on a home machine. The queue will grow — that's fine for dev.

Or use the Makefile shortcuts:

```bash
make dev          # Tab 1
make dev-worker   # Tab 2
```

## Production deployment

### 1. WireGuard (all nodes)

Encrypted mesh network for Erlang distribution across regions.

```bash
# On each node
bash scripts/wireguard_setup.sh <master|tok|syd|sg>

# After exchanging public keys:
sudo wg-quick up wg0
sudo systemctl enable wg-quick@wg0
```

Node IPs: master=10.0.0.1, tok=10.0.0.2, syd=10.0.0.3, sg=10.0.0.4

### 2. ClickHouse (master only)

```bash
bash clickhouse/setup.sh
```

Creates `ls.enrichments` (append-only log) and `ls.domains_current` (auto-maintained latest state). One INSERT point, no import scripts, no staging tables.

### 3. Start master

```bash
LS_ROLE=master LS_MODE=ctl_live \
  iex --name master@10.0.0.1 --cookie ls_prod -S mix phx.server
```

### 4. Start workers

```bash
# Tokyo
LS_ROLE=worker LS_MASTER=master@10.0.0.1 \
  iex --name worker_tok@10.0.0.2 --cookie ls_prod -S mix

# Sydney
LS_ROLE=worker LS_MASTER=master@10.0.0.1 \
  iex --name worker_syd@10.0.0.3 --cookie ls_prod -S mix

# Singapore
LS_ROLE=worker LS_MASTER=master@10.0.0.1 \
  iex --name worker_sg@10.0.0.4 --cookie ls_prod -S mix
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LS_ROLE` | `standalone` | `master`, `worker`, or `standalone` |
| `LS_MODE` | `minimal` | `ctl_live` enables CT log polling |
| `LS_MASTER` | `master@10.0.0.1` | Master node (workers only) |
| `LS_HTTP_CONCURRENCY` | `100` | HTTP connections per worker |

## Monitoring

### Dashboard

`http://master-ip:4000` — real-time queue depth, worker count, insert rate, cache usage.

### IEx (master)

```elixir
LS.Cluster.Monitor.watch()       # live dashboard, refreshes every 5s
LS.Cluster.WorkQueue.stats()     # queue depth, in/out rates
LS.Cluster.Inserter.stats()      # CH insert rate, buffer, errors
LS.CTL.poller_stats()            # CTL throughput
LS.Cache.stats()                 # CTL 5M cache, HTTP/BGP caches
Node.list()                      # connected workers
```

### IEx (worker)

```elixir
LS.Cluster.WorkerAgent.stats()   # batches processed, domains/sec
LS.Cache.stats()                 # HTTP + BGP caches
```

### Log output (master, every 30s)

```
[CLUSTER] Queue: 245K (4.9%) | In: 10,800/min | Out: 8,400/min |
          Workers: 3 (worker_tok, worker_syd, worker_sg) | Inflight: 3 |
          CH insert: 8,200/min buf=1,204
```

## ClickHouse queries

```sql
clickhouse client --database=ls

-- High-value leads
SELECT domain, http_title, http_tech, total_budget_scoring
FROM domains_current
WHERE bgp_asn_country = 'US' AND total_budget_scoring >= 20
ORDER BY total_budget_scoring DESC LIMIT 100;

-- Exact single-domain lookup
SELECT * FROM domains_current FINAL WHERE domain = 'stripe.com';

-- Domain enrichment history
SELECT enriched_at, worker, http_tech, bgp_asn_org
FROM enrichments WHERE domain = 'stripe.com' ORDER BY enriched_at;

-- Worker throughput last hour
SELECT worker, count() AS domains
FROM enrichments WHERE enriched_at > now() - INTERVAL 1 HOUR
GROUP BY worker;

-- Drop old data (instant, no vacuum)
ALTER TABLE enrichments DROP PARTITION 202601;
```

## Queue behavior

CTL produces ~180 domains/sec. Workers drain at their HTTP-bottlenecked rate.

| Workers | HTTP concurrency | Approx drain rate | Queue trend |
|---------|-----------------|-------------------|-------------|
| 1 @ 20 | 20 | ~6-10/sec | Growing fast (dev is fine) |
| 3 @ 100 | 300 | ~80-120/sec | Slowly growing, catches up overnight |
| 4 @ 100 | 400 | ~120-160/sec | Stable |
| 3 @ 150 | 450 | ~130-170/sec | Stable/draining |

### Protections

- **Hard cap**: 5M domains max in queue (~600MB). Excess dropped silently (FIFO).
- **TTL**: Domains older than 24h in queue get evicted hourly.
- **In-flight timeout**: Batches not completed in 10min get requeued.
- **Worker disconnect**: Batch requeued on timeout. Worker auto-reconnects.

## Costs

| Node | Spec | Monthly |
|------|------|---------|
| Master (NY) | Vultr 2CPU/4GB | ~$24 |
| Worker Tokyo | Vultr 1CPU/1GB | $6 |
| Worker Sydney | Vultr 1CPU/1GB | $6 |
| Worker SG | Home machine | $0 |
| **Total** | | **~$36/mo** |
