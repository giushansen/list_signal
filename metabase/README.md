# Metabase — ListSignal data health

Local, free open-source Metabase connected (read-only) to the **production
ClickHouse** on the master box. Used to eyeball the data and catch pipeline
anomalies: throughput cliffs, 5xx spikes, workers silently failing a stage.

## Architecture

```
Metabase (Docker, localhost:3000)
  └─> host.docker.internal:8123
        └─> SSH tunnel (tunnel.sh)  laptop:8123 ──> master 127.0.0.1:8123
              └─> ClickHouse `ls` DB, user `metabase` (SELECT-only, HOST LOCAL)
```

- ClickHouse on the master listens on **127.0.0.1 only** — never expose it;
  the tunnel is the only path in.
- CH user `metabase`: `GRANT SELECT ON ls.*` + `system.*`, `HOST LOCAL`,
  so even a leaked password is useless without SSH to the box.
- Credentials live in `.env.local` (gitignored).

## Start / stop

```bash
cd metabase
./tunnel.sh -f                  # 1. background SSH tunnel to prod CH
docker compose up -d            # 2. Metabase on http://localhost:3000
# stop:
docker compose down             # (data persists in the metabase-data volume)
pkill -f '8123:127.0.0.1:8123'  # kill the tunnel
```

Log in at <http://localhost:3000> with the credentials in `.env.local`.
Everything lives in the **“ListSignal Health”** collection + dashboard.

## Schema cheat-sheet

| Table | What | Use for |
|---|---|---|
| `enrichments` | Append-only log, one row per enrichment (~118M) | time series, "last 24h" |
| `domains_current` | ReplacingMergeTree MV, current state per domain | current-state counts |
| `domains_fast` | View over the MV inner table, adds `country`, `is_shopify` | app-parity queries |

Gotchas:
- `is_shopify` / `country` **only exist on `domains_fast`** (MATERIALIZED on
  the MV inner table). On `enrichments` use the same expression the MV uses:
  `http_tech LIKE '%Shopify%'` — and `inferred_country` for country.
- `enrichments` is unmerged history: recrawled domains appear multiple times.
  For "current truth" use `domains_fast`.
- ~92% of rows have `http_status = NULL` **by design** — HTTP crawling is
  filtered to high-value TLDs; most CT-log domains never get an HTTP attempt.
  Judge crawler health by *shifts* in the ratio, not its absolute level.

### The pipeline is a funnel — mind your denominators

Stages are gated, so "empty column ÷ all rows" is **not** a failure rate:

| Stage | Runs on | Empty ÷ all rows | Real failure rate |
|---|---|---|---|
| DNS | everything | 0.06 | 0.06 |
| HTTP | 42 high-value TLDs (~30% of stream) | 0.92 "no response" | **0.73** of *attempted* |
| Classifier | 2xx bodies only | 0.94 "unclassified" | **0.53** of *2xx* |
| BGP | successfully-crawled hosts only | 0.75 "empty" | **0.000** of *crawled* |
| RDAP | ~11% of rows | 0.89 "never ran" | 0.000 of *attempted* |

Query 08 uses the right-hand column. Naive ratios sit at 0.7–0.95 permanently
and hide real movement — a BGP outage would move "empty ÷ all rows" from 0.75
to 0.78 (invisible) but "empty ÷ crawled" from 0.000 to 1.000 (obvious).

## The queries (`queries/*.sql`)

Each file is loaded as a native question in the "ListSignal Health" collection.

| # | Question | What "bad" looks like |
|---|---|---|
| 01 | Discovery counts, 24h | any headline number ~0 |
| 02 | New SaaS, last 24h | empty table while 01 shows volume |
| 03 | New Shopify stores, last 24h | empty table while 01 shows volume |
| 04 | Hourly throughput, 7d | cliff to ~0 = stalled pipeline; a flat shopify/saas series while total is fine = detector/classifier died |
| 05 | Per-worker throughput, 24h | missing worker row, stale `last_seen`, or a ratio column at 1.0 (stage dead on that worker) |
| 06 | HTTP status mix, 24h vs prev | 5xx or no_response share jumping vs prev |
| 07 | Crawler errors, 24h | one error type suddenly dominating |
| 08 | Stage failure ratios, hourly 48h | any ratio creeping up hour over hour (each is measured against the rows the stage actually runs on — see funnel table above) |
| 09 | business_model mix, 24h vs prev | big share shift = classifier drift/breakage |
| 10 | Pipeline freshness | `minutes_since_last_insert` > 15 = pipeline down |

## Healthy baselines (2026-07-25)

Query 08, steady state — alert on *sustained departures*, not single hours:

| Metric | Normal | Notes |
|---|---|---|
| `http_attempt_rate` | 0.27–0.37 | the TLD gate; a drop = gate misconfigured |
| `dns_unresolved` | 0.05–0.08 | |
| `http_fail_of_attempted` | 0.67–0.84 | high but *expected* — 57% of attempts are `nxdomain` (CT-log domains with certs but no live DNS). Watch the **mix** in query 07, not this total |
| `http_5xx_of_status` | 0.02–0.03 | >0.10 sustained = real problem |
| `unclassified_of_2xx` | 0.52–0.55 | classifier confidence threshold |
| `bgp_empty_of_crawled` | **0.000** | anything above ~0.05 = BGP/Team Cymru broken |
| `rdap_fail_of_attempted` | 0.000 | suspiciously perfect — see anomaly 3 |

Throughput: ~1.7M enriched/24h, ~170–220K/hour, ~45K Shopify, ~4K SaaS.

## Known anomalies (as of 2026-07-25)

- **h1 (`worker_lsh1`) HTTP stage looks dead**: 1.23M enrichments/24h (10× any
  other worker) but `http_null_ratio` = **1.000** vs ~0.70 elsewhere. Every
  row it produces has no HTTP data — either its egress is blocked or the HTTP
  stage crashes. Query 05 shows it. Worth investigating.
- `syd1` chronically low throughput — known, outbound TLS/RDAP flakiness.
- `LS.Clickhouse.shopify_stores_last_hour` (lib/ls/clickhouse.ex:307) queries
  `enrichments … is_shopify = 1`, but that column doesn't exist on
  `enrichments` — likely erroring and returning 0 silently.
- **`rdap_error` is 0.000 in every hour ever measured.** RDAP populates only
  ~11% of rows and reports literally zero failures, which is implausible given
  syd1's known RDAP flakiness. Either failures aren't written to `rdap_error`,
  or RDAP is skipped far more than it fails. Treat this column as unverified —
  don't read "0.000" as "RDAP is healthy".
- `rate_limited` is ~14% of all HTTP attempts (~71K/24h) — we're being
  throttled at meaningful scale. Not new, but worth a look at politeness/backoff.

## Rebuilding from scratch

The Metabase app-state (questions, dashboard) lives in the `metabase-data`
Docker volume. If it's lost, re-run the loader used at setup time
(`scripts/load_metabase.sh` — idempotent-ish; it re-creates the collection,
questions and dashboard via the Metabase API from the `queries/*.sql` files).
