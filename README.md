# ListSignal

Domain intelligence platform. Ingests SSL certificates in real-time, enriches domains with DNS/HTTP/BGP/RDAP data, looks up reputation signals, and stores everything in ClickHouse.

No files in the pipeline. CTL → ETS queue → workers → ClickHouse. That's it.

---

## Quick Start — Starting & Restarting Nodes

### Prerequisites

| Dependency | Where needed | Install |
|---|---|---|
| Elixir 1.18+ / Erlang 27+ | All nodes | `asdf install erlang 27.0 && asdf install elixir 1.18.4` |
| ClickHouse | Master only | See [clickhouse.com/docs](https://clickhouse.com/docs) |
| Unbound DNS resolver | Worker nodes | `apt install unbound` |
| WireGuard | Production (all) | `apt install wireguard` |

### First-Time Setup

```bash
cd ~/Projects/list_signal
mix setup          # deps + assets
mix compile
```

### Local Development (Two Terminals)

**Terminal 1 — Master** (CTL poller + queue + inserter + dashboard):

```bash
make dev
# or manually:
LS_ROLE=master LS_MODE=ctl_live \
  iex --name master@127.0.0.1 --cookie dev_cookie -S mix phx.server
```

Dashboard: [http://localhost:4000](http://localhost:4000)

**Terminal 2 — Worker** (enriches domains):

```bash
make dev-worker
# or manually:
LS_ROLE=worker LS_MASTER=master@127.0.0.1 LS_HTTP_CONCURRENCY=20 \
  iex --name worker_dev@127.0.0.1 --cookie dev_cookie -S mix
```

### Production Startup

**Master node:**

```bash
LS_ROLE=master LS_MODE=ctl_live \
  iex --name master@$(hostname -I | awk '{print $1}') --cookie ls_prod -S mix phx.server
```

**Worker node** (repeat on each worker server):

```bash
LS_ROLE=worker LS_MASTER=master@10.0.0.1 LS_DNS_CONCURRENCY=500 \
  iex --name worker_$(hostname -s)@$(hostname -I | awk '{print $1}') --cookie ls_prod -S mix
```

### Restarting Nodes

| Scenario | What to do |
|---|---|
| **Restart a worker** | Just kill and relaunch. The master auto-requeues its in-flight batch after 10 min timeout. The worker reconnects to master on startup. |
| **Restart the master** | Workers lose connection and retry every 10s. Queue (ETS) is lost on restart — CTL will refill it. ClickHouse data is safe. |
| **Add a new worker** | Launch it with `LS_MASTER` pointing at the master. It auto-connects via Erlang distribution and starts pulling batches. |
| **Restart ClickHouse** | The Inserter buffers rows in memory and retries on the next 5s flush cycle. No data loss unless master also restarts. |
| **Restart Unbound (worker)** | `systemctl restart unbound`. DNS lookups fail briefly, domains get empty DNS fields but still flow through the pipeline. |

### Environment Variables

| Variable | Default | Values | Description |
|---|---|---|---|
| `LS_ROLE` | `standalone` | `master`, `worker`, `standalone` | Node role — what processes start |
| `LS_MODE` | `minimal` | `ctl_live`, `minimal` | Whether CTL polling is active (master only) |
| `LS_MASTER` | `master@10.0.0.1` | Erlang node name | Master address (workers only) |
| `LS_BATCH_SIZE` | `1000` | integer | Domains per batch pulled by worker |
| `LS_HTTP_CONCURRENCY` | `100` | integer | Parallel HTTP connections per worker |
| `LS_DNS_CONCURRENCY` | `500` | integer | Parallel DNS lookups per worker |
| `LS_RDAP_CONCURRENCY` | `3` | integer | Parallel RDAP queries per worker |
| `LS_RDAP_RATE` | `2` | integer | RDAP queries per second per server |

---

## Databases

### ClickHouse (enrichment data — master node)

**Setup** (first time or schema changes):

```bash
bash clickhouse/setup.sh        # creates database + tables
# or for upgrades:
clickhouse client < clickhouse/migrate_v3.sql
```

**Two objects:**

| Object | Type | Purpose |
|---|---|---|
| `ls.enrichments` | Table (MergeTree) | Append-only log. Partitioned by month. Every enriched domain gets a row here. |
| `ls.domains_current` | Materialized View (ReplacingMergeTree) | Auto-maintained latest state per domain. Deduplicates on `domain`, keeps newest `enriched_at`. |

One INSERT point (the Inserter). No staging tables. No import scripts.

**Useful queries:**

```sql
-- Row count
SELECT count() FROM ls.enrichments;

-- Today's throughput
SELECT count() FROM ls.enrichments WHERE enriched_at >= today();

-- Latest state for a domain
SELECT * FROM ls.domains_current FINAL WHERE domain = 'stripe.com';
```

### SQLite (application data — via Ecto)

Used for users, accounts, settings. Not for domain data. Lives at the default Ecto path. Rarely needs manual intervention.

---

## System Architecture — The Big Picture

```
┌─────────────────────────────────────────────────────────────────────┐
│  MASTER NODE  (Vultr NY)                                            │
│                                                                     │
│  ┌──────────┐    ┌──────────────┐    ┌──────────┐    ┌───────────┐ │
│  │ CTL      │───>│ ETS WorkQueue│───>│ Inserter │───>│ClickHouse │ │
│  │ Poller   │    │  (5M cap)    │<───│ (buf 5K) │    │           │ │
│  └──────────┘    └──────┬───────┘    └──────────┘    └───────────┘ │
│  ~180 dom/s             │ ▲                                         │
│  6+ CT logs             │ │ enriched rows                           │
│                         │ │                                         │
│  ┌──────────┐           │ │          ┌───────────┐                  │
│  │ Monitor  │           │ │          │ Phoenix   │                  │
│  │ (30s log)│           │ │          │ Dashboard │                  │
│  └──────────┘           │ │          │ :4000     │                  │
│                         │ │          └───────────┘                  │
│  ┌──────────┐           │ │                                         │
│  │ Tranco   │           │ │                                         │
│  │ Majestic │           │ │  Erlang distribution                    │
│  │ Blocklist│           │ │  over WireGuard                         │
│  └──────────┘           ▼ │                                         │
└─────────────────────────┼─┼─────────────────────────────────────────┘
                          │ │
            ┌─────────────┘ └──────────────┐
            ▼                              ▼
┌───────────────────────┐    ┌───────────────────────┐
│  WORKER (Tokyo)       │    │  WORKER (Sydney)      │
│                       │    │                       │
│  Pull 1000 domains    │    │  Pull 1000 domains    │
│  ├─ DNS  (500 conc)   │    │  ├─ DNS  (500 conc)   │
│  ├─ HTTP (100 conc)   │    │  ├─ HTTP (100 conc)   │
│  ├─ BGP  (batched)    │    │  ├─ BGP  (batched)    │
│  ├─ RDAP (3 conc)     │    │  ├─ RDAP (3 conc)     │
│  └─ Reputation (ETS)  │    │  └─ Reputation (ETS)  │
│  Return enriched rows │    │  Return enriched rows │
└───────────────────────┘    └───────────────────────┘
```

---

## Data Flow — Step by Step

### Pipeline 1: CTL Ingestion (Master)

**Where:** `lib/ls/ctl/poller.ex`

The Poller watches 6+ Certificate Transparency logs (Google Argon/Xenon, Cloudflare Nimbus, DigiCert, Sectigo) and discovers new domains as SSL certificates are issued worldwide.

```
CT Log APIs ──> Poller (adaptive multi-worker)
                  │
                  ├─ Parse X.509 cert ──> extract domain, issuer, subdomains
                  │
                  ├─ FILTER 1: SharedHostingFilter
                  │   Skip *.pages.dev, *.netlify.app, etc.
                  │   (lib/ls/ctl/shared_hosting_filter.ex)
                  │
                  ├─ FILTER 2: Smart CTL Cache (dedup)
                  │   ETS table, 5M entries max
                  │   Tracks cert_count per domain
                  │   Only :new domains pass through
                  │   Auto-detects platforms (high cert count = platform)
                  │
                  └─ WorkQueue.enqueue(cert_data)
                     Only called when track_result == :new
```

**What gets queued (cert_data map):**

| Field | Example | Description |
|---|---|---|
| `ctl_domain` | `"stripe.com"` | Base domain (parsed from cert) |
| `ctl_tld` | `"com"` | TLD or ccTLD |
| `ctl_issuer` | `"Let's Encrypt"` | Certificate issuer |
| `ctl_subdomain_count` | `3` | Number of subdomains on cert |
| `ctl_subdomains` | `"www\|api\|docs"` | Pipe-separated subdomain list |

**Throughput:** ~180 domains/sec, ~15M/day.

---

### Pipeline 2: Queue → Worker Distribution (Master ↔ Workers)

**Where:** `lib/ls/cluster/work_queue.ex`, `lib/ls/cluster/worker_agent.ex`

```
WorkQueue (ETS ordered_set, 5M cap)
    │
    ├─ Worker calls: GenServer.call(WorkQueue, {:dequeue, 1000})
    │   Returns {:ok, batch_id, [domain_maps]}
    │
    ├─ Worker processes batch (see Pipeline 3)
    │
    ├─ Worker returns: GenServer.cast(WorkQueue, {:complete, batch_id, enriched_rows})
    │   Rows go to Inserter buffer
    │
    └─ Safety: if worker dies, in-flight batch re-queued after 10 min timeout
```

**Queue behavior:**

| Condition | What happens |
|---|---|
| Queue full (5M) | New domains silently dropped. CTL keeps running. |
| Queue empty | Worker waits 30s, then retries. |
| Worker dies mid-batch | Batch auto-requeued after 10 min. |
| Master restarts | Queue lost (ETS). CTL refills it. |

---

### Pipeline 3: Worker Enrichment (Workers)

**Where:** `lib/ls/cluster/worker_agent.ex`

This is the core pipeline. Each batch of 1000 domains goes through these stages:

```
┌─────────────────────────────────────────────────────────────────┐
│  WORKER ENRICHMENT PIPELINE (per batch of 1000 domains)         │
│                                                                 │
│  STAGE 1: DNS  ─────────────────────────────────────────────    │
│  (sequential, must finish before parallel stage)                │
│  All 1000 domains, 500 concurrent via Task.async_stream        │
│  Unbound resolver: A, AAAA, MX, TXT, CNAME                    │
│  Timeout: 15s per domain. Failed = empty fields, still flows.  │
│                                                                 │
│            │                                                    │
│            ▼                                                    │
│  CLASSIFY  ─────────────────────────────────────────────────    │
│  Split DNS results into candidates for each parallel stage:     │
│  • HTTP candidates: has IP + not cached + not blocked +         │
│                     not registry TLD + passes DomainFilter      │
│  • BGP candidates:  has IP (all of them)                        │
│  • RDAP candidates: has IP + not cached + not blocked +         │
│                     not registry TLD                            │
│                                                                 │
│            │                                                    │
│            ▼                                                    │
│  STAGE 2: PARALLEL (Task.async for each)  ──────────────────   │
│                                                                 │
│  ┌─────────────────┐  ┌──────────────┐  ┌─────────────────┐   │
│  │ HTTP             │  │ BGP          │  │ RDAP            │   │
│  │ 100 concurrent   │  │ Batched      │  │ 3 concurrent    │   │
│  │ Mint TLS client  │  │ Team Cymru   │  │ Per-server rate │   │
│  │ Per-IP rate limit│  │ IP→ASN map   │  │ limited         │   │
│  │ 25s timeout      │  │ 60s timeout  │  │ 15s timeout     │   │
│  │ Tech detection   │  │              │  │ IANA bootstrap  │   │
│  │ App detection    │  │              │  │                 │   │
│  │ Language detect  │  │              │  │                 │   │
│  │ Page extraction  │  │              │  │                 │   │
│  └─────────────────┘  └──────────────┘  └─────────────────┘   │
│                                                                 │
│            │                                                    │
│            ▼                                                    │
│  STAGE 3: MERGE + REPUTATION  ──────────────────────────────   │
│  For each domain, combine DNS + HTTP + BGP + RDAP results      │
│  Add reputation lookups (pure ETS reads, no network):           │
│  • Tranco rank                                                  │
│  • Majestic rank + RefSubNets                                   │
│  • Blocklist flags (malware/phishing/disposable)                │
│  Output: flat map with all fields → return to master            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

### Pipeline 4: ClickHouse Insertion (Master)

**Where:** `lib/ls/cluster/inserter.ex`

```
Enriched rows from workers
    │
    ▼
Inserter (GenServer buffer)
    │
    ├─ Accumulates rows in memory
    ├─ Flushes every 5 seconds via ClickHouse HTTP API
    ├─ Batch size: up to 5000 rows per insert
    ├─ On failure: keeps rows, retries next cycle
    └─ On success: rows gone from memory
    │
    ▼
ls.enrichments (append-only MergeTree table)
    │
    └──> ls.domains_current (auto-updated materialized view)
```

---

### Pipeline 5: Reputation Data Loading (Master + Workers)

**Where:** `lib/ls/reputation/`

These GenServers download external reputation data into ETS tables at startup, then refresh periodically. Workers and master both run them.

```
┌────────────────────────────────────────────────────────────────┐
│  REPUTATION SOURCES  (loaded at boot, refreshed periodically)  │
│                                                                │
│  Tranco (lib/ls/reputation/tranco.ex)                          │
│  ├─ Source: Tranco top 1M list                                 │
│  ├─ Format: rank,domain CSV                                    │
│  ├─ ETS: domain → rank (Int)                                   │
│  └─ Refresh: daily                                             │
│                                                                │
│  Majestic (lib/ls/reputation/majestic.ex)                      │
│  ├─ Source: Majestic Million CSV                                │
│  ├─ ETS: domain → {rank, ref_subnets}                          │
│  └─ Refresh: daily                                             │
│                                                                │
│  Blocklist (lib/ls/reputation/blocklist.ex)                     │
│  ├─ Sources:                                                   │
│  │   malware   → URLhaus filter (gitlab.io)                    │
│  │   phishing  → Phishing filter (gitlab.io)                   │
│  │   disposable → disposable-email-domains (GitHub)            │
│  ├─ ETS: domain → :malware | :phishing | :disposable           │
│  ├─ Priority: malware > phishing > disposable                  │
│  └─ Refresh: every 12 hours                                    │
│                                                                │
│  TLDFilter (lib/ls/reputation/tld_filter.ex)                   │
│  ├─ Detects registry domains (co.uk, com.au, etc.)             │
│  └─ Used to skip HTTP/RDAP for registries                      │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## Filtering & Rate Protection Rules

### Where Domains Get Filtered (and why)

Every filter exists to avoid wasting compute on junk domains. Here is the sequence from CTL ingestion to enrichment:

| # | Filter | Where | Module | What it rejects |
|---|---|---|---|---|
| 1 | Shared Hosting | CTL Poller | `LS.CTL.SharedHostingFilter` | `*.pages.dev`, `*.netlify.app`, `*.vercel.app`, etc. Compile-time list from `signatures/shared_hosting_platforms.txt` |
| 2 | CTL Dedup Cache | CTL Poller | `LS.Cache` (`:ctl_track`) | Domains already seen. 5M entry cap. Also auto-detects "platforms" (high cert count). |
| 3 | Platform Detection | CTL Poller | `LS.Cache` (`:ctl_is_platform?`) | Domains the cache heuristically identifies as hosting platforms. |
| 4 | HTTP Politeness Cache | Worker classify | `LS.Cache` (`:http_lookup`) | Domains already crawled recently. Prevents re-hitting the same domain. |
| 5 | Blocklist Check | Worker classify | `LS.Reputation.Blocklist` | Malware, phishing, disposable email domains. Skips expensive HTTP/RDAP. |
| 6 | Registry TLD Check | Worker classify | `LS.Reputation.TLDFilter` | Registry domains like `co.uk`, `com.au`, `cn.com`. Not real businesses. |
| 7 | DomainFilter | Worker classify (HTTP only) | `LS.HTTP.DomainFilter` | 4 checks (see below). Only high-value domains get HTTP crawled. |
| 8 | RDAP Cache | Worker classify | `LS.Cache` (`:rdap_lookup`) | Domains already RDAP-queried recently. |

### DomainFilter: The HTTP Quality Gate

**Where:** `lib/ls/http/domain_filter.ex`

A domain must pass ALL four checks to be HTTP-crawled:

| Check | Rule | Example pass | Example fail |
|---|---|---|---|
| High-value TLD | Must end with a TLD from `signatures/high_value_tlds.txt` (~45 TLDs: com, net, io, co.uk, etc.) | `stripe.com` | `example.xyz` |
| Not junk domain | Name part ≥ 4 chars, no 2+ consecutive digits, no multiple hyphens | `acme.com` | `aa.io`, `test123456.com`, `x-y-z.com` |
| Has MX records | DNS MX must be non-empty (domain can send mail) | Domain with `mx.google.com` | Domain with no MX |
| Has SPF record | DNS TXT must contain `v=spf1` (proper email setup) | `v=spf1 include:...` | Random or empty TXT |

### Rate Limiting

| Component | Mechanism | Details |
|---|---|---|
| **HTTP Client** | IP-based rate limiter | `LS.HTTP.IPRateLimiter` — max 1 request per IP per 1000ms. Returns `{:wait, ms}` if too soon; worker sleeps then retries. |
| **RDAP Client** | Per-server rate limiter | `LS_RDAP_RATE` env var (default 2/sec). Each RDAP server tracked independently in ETS. Excess returns `:rate_limited` and domain is skipped. |
| **CTL Poller** | Adaptive worker scaling | Auto-scales 2–100 workers per CT log based on how far behind it is. Google logs cap at batch_size=32; Cloudflare allows 512. |
| **WorkQueue** | Capacity cap | 5M max. Beyond that, new domains silently dropped. No backpressure on CTL. |

---

## What Each Module Does — Where to Look

### Master-Side Modules (`lib/ls/`)

| Module | File | What it does |
|---|---|---|
| `LS.CTL.Poller` | `lib/ls/ctl/poller.ex` | Polls 6+ CT logs, parses X.509 certs, filters, enqueues new domains |
| `LS.CTL.DomainParser` | `lib/ls/ctl/domain_parser.ex` | Extracts base domain + TLD, handles ccTLDs like `co.uk` |
| `LS.CTL.SharedHostingFilter` | `lib/ls/ctl/shared_hosting_filter.ex` | Compile-time list of shared hosting platforms to skip |
| `LS.Cluster.WorkQueue` | `lib/ls/cluster/work_queue.ex` | ETS ordered_set queue. 5M cap. In-flight timeout tracking. |
| `LS.Cluster.Inserter` | `lib/ls/cluster/inserter.ex` | Buffers rows, batch-inserts to ClickHouse every 5s via HTTP API |
| `LS.Cluster.Monitor` | `lib/ls/cluster/monitor.ex` | Logs cluster stats every 30s, alerts on queue pressure |
| `LS.Cache` | `lib/ls/cache.ex` | CTL dedup (5M), HTTP politeness, BGP IP→ASN, RDAP dedup — all ETS |

### Worker-Side Modules (`lib/ls/`)

| Module | File | What it does |
|---|---|---|
| `LS.Cluster.WorkerAgent` | `lib/ls/cluster/worker_agent.ex` | Main loop: connect → pull batch → enrich → return → repeat |
| `LS.DNS.Resolver` | `lib/ls/dns/resolver.ex` | Unbound-backed DNS (A, AAAA, MX, TXT, CNAME) |
| `LS.HTTP.Client` | `lib/ls/http/client.ex` | Mint-based HTTPS client. TLS 1.2/1.3. IP rate limiting. Redirect following. |
| `LS.HTTP.DomainFilter` | `lib/ls/http/domain_filter.ex` | Quality gate: high-value TLD + not junk + MX + SPF |
| `LS.HTTP.TechDetector` | `lib/ls/http/tech_detector.ex` | Pattern-matches response for tech stack (WordPress, Shopify, etc.) |
| `LS.HTTP.AppDetector` | `lib/ls/http/app_detector.ex` | Detects apps/tools from page content + tech signals |
| `LS.HTTP.LanguageDetector` | `lib/ls/http/language_detector.ex` | Detects page language from body/headers/title |
| `LS.HTTP.PageExtractor` | `lib/ls/http/page_extractor.ex` | Extracts internal pages and emails from HTML |
| `LS.HTTP.IPRateLimiter` | `lib/ls/http/ip_rate_limiter.ex` | Per-IP rate limiting for HTTP crawling |
| `LS.HTTP.PerformanceTracker` | `lib/ls/http/performance_tracker.ex` | Tracks timing buckets, errors, throughput. Logs every 15 min. |
| `LS.BGP.Resolver` | `lib/ls/bgp/resolver.ex` | Team Cymru bulk IP→ASN queries via DNS |
| `LS.RDAP.Client` | `lib/ls/rdap/client.ex` | IANA bootstrap → per-TLD RDAP server → registrar/dates/nameservers |
| `LS.Reputation.Tranco` | `lib/ls/reputation/tranco.ex` | Downloads + loads Tranco top 1M into ETS |
| `LS.Reputation.Majestic` | `lib/ls/reputation/majestic.ex` | Downloads + loads Majestic Million into ETS |
| `LS.Reputation.Blocklist` | `lib/ls/reputation/blocklist.ex` | Downloads malware/phishing/disposable lists into ETS |
| `LS.Reputation.TLDFilter` | `lib/ls/reputation/tld_filter.ex` | Heuristic: is this domain a TLD registry? |
| `LS.Signatures` | `lib/ls/signatures.ex` | Loads CSV scoring rules into ETS at boot |

### Web / Dashboard (`lib/ls_web/`)

| Module | File | What it does |
|---|---|---|
| `LSWeb.DashboardLive` | `lib/ls_web/live/dashboard_live.ex` | LiveView dashboard. Shows queue, workers, pipeline stages, errors. Refreshes every 3s. |
| `LSWeb.Endpoint` | `lib/ls_web/endpoint.ex` | Phoenix endpoint |
| `LSWeb.Router` | `lib/ls_web/router.ex` | Routes |

### Utility

| Module | File | What it does |
|---|---|---|
| `LS.Pipeline` | `lib/ls/pipeline.ex` | Manual/debug tool: `LS.Pipeline.run("stripe.com", verbose: true)`. Not used in production flow. |

---

## Signatures (Scoring Rules)

Plain CSV/TXT files loaded into ETS at boot by `LS.Signatures.load_all()`. To add a rule, add a line to the file and restart.

| File | Location | Purpose |
|---|---|---|
| `shared_hosting_platforms.txt` | `lib/ls/ctl/signatures/` | Domains to skip in CTL (*.pages.dev, etc.) |
| `cctlds.txt` | `lib/ls/ctl/signatures/` | Country-code TLDs for domain parsing (co.uk, com.au, etc.) |
| `high_value_tlds.txt` | `lib/ls/http/signatures/` | TLDs worth HTTP-crawling (~45: com, net, io, co.uk, etc.) |
| `tld.csv`, `issuer.csv`, `subdomain.csv` | `lib/ls/ctl/signatures/` | CTL scoring rules |
| `txt.csv`, `mx.csv` | `lib/ls/dns/signatures/` | DNS scoring rules |
| `tech.csv`, `tools.csv`, `cdn.csv`, `blocked.csv`, `server.csv` | `lib/ls/http/signatures/` | HTTP detection patterns |
| `asn_org.csv`, `country.csv`, `prefix.csv` | `lib/ls/bgp/signatures/` | BGP scoring rules |

---

## ClickHouse Schema — All Columns

Every enriched domain becomes one row with these fields:

| Column Group | Columns | Source |
|---|---|---|
| **Meta** | `enriched_at`, `worker`, `domain` | System |
| **CTL** | `ctl_tld`, `ctl_issuer`, `ctl_subdomain_count`, `ctl_subdomains` | CTL Poller |
| **DNS** | `dns_a`, `dns_aaaa`, `dns_mx`, `dns_txt`, `dns_cname` | DNS Resolver |
| **HTTP** | `http_status`, `http_response_time`, `http_blocked`, `http_content_type`, `http_tech`, `http_apps`, `http_language`, `http_title`, `http_meta_description`, `http_pages`, `http_emails`, `http_error` | HTTP Client + detectors |
| **BGP** | `bgp_ip`, `bgp_asn_number`, `bgp_asn_org`, `bgp_asn_country`, `bgp_asn_prefix` | BGP Resolver |
| **RDAP** | `rdap_domain_created_at`, `rdap_domain_expires_at`, `rdap_domain_updated_at`, `rdap_registrar`, `rdap_registrar_iana_id`, `rdap_nameservers`, `rdap_status`, `rdap_error` | RDAP Client |
| **Reputation** | `tranco_rank`, `majestic_rank`, `majestic_ref_subnets`, `is_malware`, `is_phishing`, `is_disposable_email` | Reputation modules |

Multi-value fields use pipe separators: `"1.2.3.4|5.6.7.8"`.

---

## Monitoring & Debugging

### Monitor Log Line (every 30s)

```
[CLUSTER] Queue: 245K (4.9%) | In: 10,800/min | Out: 8,400/min | Workers: 3 | CH: 8,200/min | Rep: T:1M M:1M B:245K
```

### What to Watch

| Signal | Meaning | Action |
|---|---|---|
| Queue depth growing | Workers too slow | Add worker nodes or increase concurrency |
| Queue at 80%+ | Warning in logs | Urgent: add capacity |
| Zero workers connected | Warning in logs | Check worker nodes, WireGuard, cookies |
| CH insert errors > 0 | ClickHouse problem | Check CH logs, disk space, connectivity |
| Drain rate < enqueue rate | Normal at peak | Queue grows, off-peak catches up |
| DNS resolve % < 30% | DNS resolver issue | Check Unbound, `systemctl status unbound` |

### IEx Debugging

```elixir
# Queue stats
LS.Cluster.WorkQueue.stats()

# Inserter stats
LS.Cluster.Inserter.stats()

# Test single domain through full pipeline
LS.Pipeline.run("stripe.com", verbose: true)

# Check individual stages
LS.Pipeline.dns("stripe.com")
LS.Pipeline.rdap("stripe.com")
LS.Pipeline.reputation("stripe.com")
LS.Pipeline.should_crawl?("stripe.com")

# Reputation lookups
LS.Reputation.Tranco.lookup("google.com")    # => 1
LS.Reputation.Blocklist.blocked?("malware.com")  # => true

# Cache stats
LS.Cache.stats()
```

---

## WireGuard Setup (Production)

All production nodes need WireGuard for encrypted Erlang distribution across regions. See `scripts/node_install.sh` for automated setup. The mesh connects master (NY) with workers (Tokyo, Sydney, Singapore).

---

## Adding Features — Checklist

1. Pipeline or web? Pipeline code → `lib/ls/`. Web code → `lib/ls_web/`.
2. No file I/O in the data pipeline. Everything is in-memory.
3. New enrichment source? Call it from `WorkerAgent.enrich_batch/4`.
4. New column? Update `LS.Cluster.Inserter.@columns` AND `clickhouse/schema.sql`.
5. New metric? Update `LS.Cluster.Monitor` and the LiveView dashboard.
6. New scoring rule? Add a line to the appropriate CSV in `signatures/`.
7. Run `mix precommit` when done.