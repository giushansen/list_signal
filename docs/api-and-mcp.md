# ListSignal Developer API + MCP server

Phase 1 of the AI-first surface (shipped 2026-08-29): a read-only,
key-authenticated REST API, an OpenAPI 3.1 contract, and a stateless MCP
server, all sharing one auth/quota/tracking stack. Revised 2026-10-27:
one filter grammar with the dashboard, rows as the metered unit, free
counts. This document is the map; the contract itself lives at
`/openapi.json`, `/developers` and `/data`.

## Architecture

```
request → LSWeb.Plugs.ApiAuth ──────────────┐
  (Bearer/X-API-Key → SHA-256 lookup in     │
   SQLite; per-minute ETS rate limit;       │
   monthly rows pool shared with the CSV;   │
   free calls skip the pool; RFC 9457)      │
                                            ▼
   /api/v1/* → LSWeb.ApiV1Controller ──→ LS.ApiData ──→ LS.Query (names) + LS.Explorer (SQL) ──→ ClickHouse
   /mcp      → LSWeb.McpController  ───↗
   /dashboard, /dashboard/export ─────→ LS.Query + LS.Explorer (the same two)
success only → LS.ApiKeys.record_usage_async(key, rows)  (SQLite counter, monthly row)
             → LS.Umami.track_async                      (server-side event)
             → LS.ApiAudit.log_async                     (ClickHouse api_request_log)
```

Key decisions and why:

- **One filter grammar** (`LS.Query`, 2026-10-27). The dashboard, its CSV
  link, `/search`, `/count`, `/query` and the MCP tools accept the same
  names with the same meaning. The SQL lives in `LS.Explorer.clauses/1`;
  `LS.ApiData.conditions/1` keeps a handful of clauses whose exact text
  the API promised (single `has()` for a technology, the band equalities
  on `estimated_*`) and delegates everything else. The OpenAPI
  parameters, the MCP input schemas, the /developers table and the /data
  page are generated from the grammar, so they cannot drift.
  `test/ls/query_parity_test.exs` holds the Explorer and the API to one
  meaning per name.
- **One base scope.** Every list, count and export runs in
  `http_title != '' AND estimated_junk = ''` (3.66M title-less rows and
  373K junk rows out of 26.9M on the day it shipped). The API had always
  applied it; the dashboard had not, so the same filter counted
  differently on the two surfaces. `include_junk=true` lifts the junk
  part only. `LS.LandingCache.business_count` uses the same scope so the
  number an agent cites is the number it can query.
- **Rows are the unit** (`LS.Plans`). One monthly pool per account,
  spent as CSV lines, search results, company records or change rows.
  A call costs the rows it returns (an empty one costs one). Counts,
  group-bys, stats and the technology directory are free and are not
  refused when the pool is spent (`ApiAuth.free_call?/1`), so an agent
  can always size a segment. Rate limits are the plan's searches a
  minute, per key, the same number the dashboard enforces.
- **Success-only, async usage recording**: an agent never pays for a
  miss, and a slow SQLite write can never slow a response.
- **Stateless MCP** (Streamable HTTP, JSON-RPC 2.0, no SSE, no sessions):
  valid per spec, works with Claude/Cursor/most clients via API-key
  headers, and needs zero new infrastructure. OAuth 2.1 + Dynamic Client
  Registration is Phase 2 and unlocks the ChatGPT connector surface.
- **Keys**: `ls_` + 24 random bytes. Auth reads only the SHA-256; an
  AES-256-GCM copy keyed from `secret_key_base` lets the owner's Settings
  page show the key again (`LS.ApiKeys.Vault`, 2026-10-26). A user may
  hold several named keys (one per connector), names unique among active
  keys, each revocable alone. All of a user's keys share the plan's
  monthly rows with the CSV export; the per-minute rate limit is per key.

## Endpoints and tools

| REST | MCP tool | Costs | Does |
|---|---|---|---|
| `GET /api/v1/count` | `listsignal_count` | nothing | how many match the filters |
| `GET /api/v1/search` | `listsignal_search_companies` | rows returned | one page, target ranking, `total=true` adds the count |
| `GET /api/v1/query` | `listsignal_query` | rows returned (`limit=0` free) | total, `group_by` counts, chosen `fields`, up to 500 rows on Pro and Scale |
| `GET /api/v1/company/:domain` | `listsignal_get_company` | one row | the full record, changes, email verdicts, people |
| `GET /api/v1/changes` | `listsignal_changes` | rows returned | the change feed, newest first |
| `GET /api/v1/technologies` | | nothing | the technology directory |
| `GET /api/v1/stats` | `listsignal_dataset_stats` | nothing | live dataset numbers |

Plans without addresses never receive one: `http_emails` and
`http_phone` are gated on `/company`, blanked in the CSV, and an
"email added" change row has its value blanked on `/changes`, the
Signals CSV and the MCP tool (`McpController.gate_changes/2`).

## MCP client config

```json
{
  "mcpServers": {
    "listsignal": {
      "type": "http",
      "url": "https://listsignal.com/mcp",
      "headers": { "Authorization": "Bearer ls_YOUR_KEY" }
    }
  }
}
```

claude.ai's custom connectors take a URL only: `https://listsignal.com/mcp/k/ls_YOUR_KEY`.

## Registry + directory submissions (the distribution work)

The public repo `listsignal-mcp` (README, `server.json`) describes the
server for the registries; the official registry entry is
`com.listsignal/listsignal`. Republish after a tool-list change:

```bash
mcp-publisher login http --domain listsignal.com --private-key "$(cat ~/.config/listsignal/mcp-registry-ed25519.hex)"
mcp-publisher publish
```

Submission steps, in ROI order: official registry, Smithery, mcp.so,
PulseMCP, Glama, cursor.directory, awesome-mcp-servers, Postman, APIs.guru,
Datarade. State of each lives in `devops/listsignal/mcp-registry.md`.

## Phase 2 (not built, in order of unlock)

OAuth 2.1 + DCR (→ ChatGPT Apps + connector directory) → Stripe Billing
Meters for rows above the plan → x402 for walk-up agent payments.
