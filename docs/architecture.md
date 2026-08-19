# Architecture

ListSignal discovers newly-certificated domains from Certificate Transparency
logs, enriches them across a distributed worker fleet, and serves the result
as a searchable directory of businesses (Shopify stores, SaaS, agencies, …).

```
                        ┌──────────────── MASTER (ls-master) ────────────────┐
 CT logs (8 sources) ──▶│ CTL.Poller ─▶ Cluster.WorkQueue (ETS, capped, TTL) │
                        │        ▲                 │ dequeue (batches)       │
                        │ Recrawl.Scheduler ───────┘                         │
                        │                                                    │
                        │ Cluster.Inserter ─▶ ClickHouse (enrichments,       │
                        │   ▲ (quality guard)      domains_current MV)      │
                        │   │                       ▲                        │
                        │ LSWeb (Phoenix) ──────────┘  SQLite (users/plans)  │
                        └───┼────────────────────────────────────────────────┘
                            │ rows                     Erlang distribution
                            │                          over WireGuard mesh
        ┌───────────────────┴─────────────────────────────────┐
        │            WORKERS (11 nodes, LS_ROLE=worker)       │
        │  Cluster.WorkerAgent: pulls a batch, runs stages:   │
        │   DNS ─▶ [HTTP ∥ BGP ∥ RDAP] ─▶ classify ─▶ merge   │
        └─────────────────────────────────────────────────────┘
```

## Node roles

One OTP codebase, role-selected at boot by `LS_ROLE` (see `LS.Application`):

| Role | Runs | Where |
|---|---|---|
| `master` | `LS.CTL.Poller`, `LS.Cluster.WorkQueue`, `LS.Cluster.Inserter`, `LS.Cluster.Monitor`, `LS.Recrawl.Scheduler`, `LS.Cluster.Compactor`, `LS.Verification.Scheduler`, Phoenix web | ls-master (also hosts ClickHouse + SQLite) |
| `worker` | `LS.Cluster.WorkerAgent` + resolvers/caches | 11 nodes; names derived at boot as `worker_<host>@<wg0-ip>` |
| `standalone` | both | local dev (`make dev`) |

Nodes form a mesh over WireGuard (`10.0.0.0/24`); workers connect to
`master@10.0.0.1` via Erlang distribution and everything cluster-side is
plain `GenServer.call/cast` across nodes — there is no HTTP API between nodes.

## The work loop

1. **Discovery** — `LS.CTL.Poller` tails 8 CT logs, parses certificates
   (`LS.CTL.DomainParser`), filters obvious junk, and enqueues
   `%{ctl_domain: d, source: :ctl}` items.
2. **Queueing** — `LS.Cluster.WorkQueue` is a bounded in-memory queue
   (ETS, 3M cap, 24h TTL). When full, `enqueue/1` returns `:queue_full` and
   the item is dropped — inflow shedding is deliberate.
3. **Pulling** — each `LS.Cluster.WorkerAgent` requests batches (default
   1000 domains) from the master. In-flight batches are tracked; a batch not
   completed within 10 minutes is requeued (worker died).
4. **Enrichment** — per batch, on the worker:
   - **DNS** (`LS.DNS.Resolver`) — A/AAAA/MX/TXT/CNAME via *pinned* local
     Unbound. Runs for every domain.
   - **HTTP** (`LS.HTTP.Client` + detectors) — only for domains passing
     `LS.HTTP.DomainFilter` (Tranco-ranked, or high-value TLD + MX + SPF +
     not-junk). Fetches the homepage (and select secondary pages), extracts
     title/tech/apps/language/schema, classifies business model & industry
     (`LS.ML.Classifier`, sentence embeddings).
   - **BGP** (`LS.BGP.Resolver`) — IP → ASN/org/country via Team Cymru whois.
   - **RDAP** (`LS.RDAP.Client`) — registrar & domain dates, rate-limited
     per registry.
   Stages run concurrently per batch (`Task.async_stream`); one stage
   failing or timing out never kills the batch.
5. **Merge** — `LS.Pipeline.merge_row/8` flattens all stage output into one
   55-column row (single source of truth for row shape).
6. **Insert** — rows are cast to `LS.Cluster.Inserter` on the master, which
   buffers (5s / 5000 rows), applies a per-worker **quality guard**
   (a worker whose rows stop carrying enrichment gets quarantined — see the
   h1 case study), and bulk-inserts into ClickHouse.

## Storage

| Store | What | Notes |
|---|---|---|
| ClickHouse `ls.enrichments` | append-only log, one row per enrichment | 90-day TTL; recrawls duplicate domains |
| ClickHouse `ls.domains_current` | `ReplacingMergeTree(enriched_at)` MV keyed on domain | *the product table* — newest row wins |
| ClickHouse `ls.domains_fast` | view adding materialized `country`, `is_shopify` | what web queries use (`LS.Clickhouse`) |
| ClickHouse `ls.daily_*` | SummingMergeTree daily aggregates | kept forever; feed dashboards |
| ClickHouse `ls.verified_facts` / `verified_source_records` / `verification_runs` | pipeline 3: facts per (domain, fact, source), the persisted source archive, the dated run log | `ReplacingMergeTree(fetched_at)`; see Verification below |
| SQLite (`LS.Repo`) | users, plans, Stripe state | the only critical durable state; hourly backups |

**Newest-row-wins is a sharp edge**: a worker writing *hollow* rows silently
replaces good data. That's what the Inserter guard protects against.

Accuracy of what these tables *say* (classification, revenue, junk detection)
is measured against a hand-labeled golden set — see
[data-quality.md](data-quality.md).

## Verification (pipeline 3)

Discovery finds, Enrichment reads, **Verification proves**: authoritative
sources are ingested on the master and their facts attached to domains we
already hold. Code under `LS.Verification.*`; design and rules in that
module's docs.

```
 Wikidata SPARQL ─┐                                  verification_runs      (dated fetch log)
 YC Algolia ──────┤  LS.Verification.Scheduler       verified_source_records (every parsed record, matched or not)
 SEC EDGAR bulk ──┼─▶ one source at a time ─▶ tiers ─▶ verified_facts        (domain, fact, source) newest wins
 Companies House ─┤  (master, plain HTTP,      │                │
 Sirene + INPI ───┘   our UA, ≥1 s per host)   │                └─▶ Compactor ─▶ businesses.verified_*
                                               │                                 (source precedence, never recency)
                        website URL → registrable domain → exact row in domains_current   = 'website'
                        legal name key + country → UNIQUE label in businesses (both sides) = 'name_country'
```

- **Two match tiers, nothing fuzzy.** A wrong "verified" link is worse than
  none, so the name tier is precision-first and expected to match a minority;
  its per-source rate (`LS.Verification.match_report/0`) is what decides
  whether an LLM-assisted linker over the persisted unmatched records is
  worth building.
- **`businesses` gets new sparse columns only** — `verified_revenue`,
  `verified_revenue_source`, `verified_employees`, `verified_employees_source`,
  `mission_summary`. `estimated_*` keeps its writer and meaning. Readers
  (explorer, store page, lookup, CSV) show verified when present, else the
  estimate; explorer filters match the shown value.
- **Precedence** — revenue `sec_edgar > companies_house > inpi > wikidata`,
  employees `wikidata > sirene > companies_house > yc`.
- **Bounded memory by construction**: archives are streamed (`unzip -p` port,
  `:zip.foldl`), inserts go in 5 000-row chunks, the name-tier lookup table
  is rebuilt in 16 hash shards, and the compactor's verified join is scoped
  to the slice like every other join.
- Every run is logged with URL, snapshot, byte and record counts and matches
  per tier; downloaded snapshots live under `/home/ls/verification/<source>/<date>/`.

## Recrawl

`LS.Recrawl.Scheduler` (master) re-enqueues stale domains every 6h:
digital businesses (Ecommerce/SaaS/Tool/Marketplace/Agency) after 7 days,
everything else after 30. Recrawl items carry the same `:ctl_domain` key as
CT items — workers process both identically.

## Web

Phoenix (`LSWeb`) on the master serves the public directory
(`/shopify/:slug`, `/website/:slug`, `/top/*`, `/compare/*`), SEO pages from
`domains_fast`, and the account/billing area backed by SQLite + Stripe.

## Operational invariants worth knowing

- Every service must be `systemctl enable`d — template units get no preset.
- Deploys build from a fresh clone of `origin/master` on each node, one node
  at a time (1-core nodes: stop the worker first or the EXLA build starves).
- The whole BEAM's DNS is pinned to local Unbound at boot (see
  `LS.Application`, `pin_vm_resolver`) so OS resolver breakage cannot split
  the stages again.
- Politeness: ≥1s between requests to the same IP (`LS.HTTP.IPRateLimiter`);
  RDAP is limited per registry server.
