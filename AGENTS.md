# ListSignal — Agent Guidelines

## What this project is

ListSignal is a distributed domain intelligence platform. It ingests SSL Certificate Transparency logs in real-time on a master node, queues raw domains in ETS, distributes enrichment work (DNS, HTTP, BGP) to worker nodes across the globe, and inserts enriched rows into ClickHouse. A Phoenix LiveView dashboard on the master provides real-time monitoring.

There are no files in the data pipeline. No CSVs, no TSVs, no file rotation, no file readers. Everything flows through memory: CTL poller → ETS queue → Erlang distribution → workers → back to master → ClickHouse HTTP API.

## Architecture

```
Master (Vultr NY)                          Workers (Tokyo/Sydney/SG)
┌─────────────────────┐                   ┌──────────────────────┐
│ CTL Poller           │                   │ WorkerAgent          │
│   ↓ :new domains     │    Erlang dist    │   pull 1000 domains  │
│ ETS WorkQueue (5M)  │◄──────────────────►│   DNS  (500 conc)    │
│   ↓ completed rows   │                   │   HTTP (100 conc)    │
│ Inserter → ClickHouse│                   │   BGP  (batched)     │
│ Monitor (logs 30s)   │                   │   return rows        │
│ Phoenix Dashboard    │                   └──────────────────────┘
└─────────────────────┘
```

## Core philosophy — three pillars

### 1. Simplicity

Every module does one thing. The WorkQueue is just an ETS ordered_set with enqueue/dequeue. The Inserter is just a buffer that flushes to ClickHouse every 5 seconds. The WorkerAgent is just a loop: pull → enrich → return → repeat.

When modifying code, prefer the dumbest solution that works. No abstractions until something needs to be shared three times. No GenServer unless you actually need state or a message queue. No macros. No metaprogramming. Functions that are easy to read top-to-bottom.

If a module exceeds 200 lines, it probably does too much. Split it.

### 2. Reliability

Every enrichment stage must degrade gracefully. If DNS times out for a domain, that domain still gets empty DNS fields and continues to HTTP/BGP — it doesn't crash the batch. If HTTP gets rate-limited, it returns the error string in `http_error` — the row still gets inserted into ClickHouse with whatever data we collected.

The WorkQueue requeues batches that time out after 10 minutes. If a worker dies, its in-flight batch comes back automatically. If the queue fills up (5M cap), new domains are silently dropped — no crash, no backpressure on the CTL poller. CTL keeps running no matter what.

ClickHouse inserts can fail. The Inserter retries on the next flush cycle. If ClickHouse is down for an hour, rows buffer in memory (bounded by flush size). When it comes back, they flush.

Never let a single domain's failure affect other domains in the same batch.

### 3. Monitorability

Every component exposes a `.stats()` function that returns a plain map. The Monitor GenServer logs a one-line cluster summary every 30 seconds:

```
[CLUSTER] Queue: 245K (4.9%) | In: 10,800/min | Out: 8,400/min | Workers: 3 | CH: 8,200/min
```

If you add a new component, it must have a `.stats()` function. If you add a new metric, it goes in the Monitor log line. The Phoenix dashboard reads from these same `.stats()` functions — no separate metrics system.

Key signals to watch:
- Queue depth growing → workers too slow, add nodes or increase concurrency
- Queue at 80%+ → warning in logs, action needed
- Zero workers connected → warning in logs
- CH insert errors > 0 → ClickHouse problem
- Drain rate < enqueue rate → steady state, queue grows until off-peak catches up

## Roles and env vars

| Var | Values | Description |
|-----|--------|-------------|
| `LS_ROLE` | `master`, `worker`, `standalone` | Node role |
| `LS_MODE` | `ctl_live`, `minimal` | CTL polling (master/standalone) |
| `LS_MASTER` | `master@10.0.0.1` | Master node address (workers) |
| `LS_HTTP_CONCURRENCY` | `100` | HTTP connections per worker |

## Key modules

| Module | Role | What it does |
|--------|------|-------------|
| `LS.CTL.Poller` | master | Polls 6+ CT logs, filters platforms, feeds WorkQueue on `:new` domains |
| `LS.Cluster.WorkQueue` | master | ETS queue with 5M cap, TTL eviction, in-flight timeout tracking |
| `LS.Cluster.Inserter` | master | Buffers enriched rows, batch-inserts to ClickHouse via HTTP API |
| `LS.Cluster.Monitor` | master | Logs cluster stats every 30s, alerts on queue pressure |
| `LS.Cluster.WorkerAgent` | worker | Pull → DNS → HTTP → BGP → return loop |
| `LS.Cache` | both | CTL 5M dedup, HTTP politeness, BGP IP→ASN |
| `LS.DNS.Resolver` | worker | Unbound-backed DNS lookups (A, AAAA, MX, TXT, CNAME) |
| `LS.HTTP.Client` | worker | Mint-based HTTP client with IP rate limiting |
| `LS.HTTP.TechDetector` | worker | Pattern matching for tech stack detection |
| `LS.HTTP.DomainFilter` | worker | Quality gate: high-value TLD + MX + SPF |
| `LS.BGP.Resolver` | worker | Team Cymru IP→ASN batch queries |
| `LS.Signatures` | both | Loads CSV scoring rules into ETS at startup |

## Database

**ClickHouse** is the enrichment data store. Two objects:
- `ls.enrichments` — append-only log, partitioned by month
- `ls.domains_current` — materialized view, auto-maintained latest state per domain

One INSERT point. No staging tables. No import scripts.

**SQLite** (via Ecto) is for application data — users, accounts, settings. Not for domain data.

## Coding rules specific to this project

- No file I/O in the data pipeline. No CSVWriter, no CSVReader, no TSV, no gzip.
- The CTL poller calls `LS.Cluster.WorkQueue.enqueue/1` directly. No intermediary.
- Workers call enrichment modules (Resolver, Client, etc.) directly. No Pipeline module wrapping them.
- Every enriched row is a flat map with all fields. One row = one domain = one ClickHouse INSERT.
- All scoring happens on the worker before returning results. Master just inserts.
- ETS tables are `:public` with `read_concurrency: true`. Workers and master read freely.
- Erlang distribution connects nodes. WireGuard encrypts the transport. No HTTP APIs between nodes.
- Signature files are plain CSVs loaded into ETS at boot. To add a scoring rule, add a line to a CSV.
- `Req` is the only HTTP client for external calls (CTL API, ClickHouse inserts). `Mint` is used only by the HTTP enrichment client for raw domain crawling.

## When adding features

1. Ask: does this need to be in the data pipeline or the web app?
2. Pipeline changes go in `lib/ls/`. Web changes go in `lib/ls_web/`.
3. If it touches the data pipeline, it must not introduce file I/O.
4. If it's a new enrichment source, it gets called from `WorkerAgent.enrich_batch/2`.
5. If it adds a new column, update `LS.Cluster.Inserter.@columns` and `clickhouse/schema.sql`.
6. If it adds a new metric, update `LS.Cluster.Monitor` and the LiveView dashboard.
7. Run `mix precommit` when done.


<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs and `live_session` scopes:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - A `live_session :current_user` scope - for routes that need the current user but don't require authentication, similar to `:fetch_current_scope_for_user`
  - A `live_session :require_authenticated_user` scope - for routes that require authentication, similar to the plug with the same name
  - In both cases, a `@current_scope` is assigned to the Plug connection and LiveView socket
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes, `live_session`, and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Always pass the assign `current_scope` to context modules as first argument. When performing queries, use `current_scope.user` to filter the query results
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates or LiveViews
- **Never** duplicate `live_session` names. A `live_session :current_user` can only be defined __once__ in the router, so all routes for the `live_session :current_user`  must be grouped in a single block
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug and `live_session` as described below**

### Routes that require authentication

LiveViews that require login should **always be placed inside the __existing__ `live_session :require_authenticated_user` block**:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :require_authenticated_user,
        on_mount: [{LSWeb.UserAuth, :require_authenticated}] do
        # phx.gen.auth generated routes
        live "/users/settings", UserLive.Settings, :edit
        live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
        # our own routes that require logged in user
        live "/", MyLiveThatRequiresAuth, :index
      end
    end

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

LiveViews that can work with or without authentication, **always use the __existing__ `:current_user` scope**, ie:

    scope "/", MyAppWeb do
      pipe_through [:browser]

      live_session :current_user,
        on_mount: [{LSWeb.UserAuth, :mount_current_scope}] do
        # our own routes that work with or without authentication
        live "/", PublicLive
      end
    end

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->