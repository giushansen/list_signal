# ListSignal Developer API + MCP server

Phase 1 of the AI-first surface (shipped 2026-08-29): a read-only,
key-authenticated REST API, an OpenAPI 3.1 contract, and a stateless MCP
server, all sharing one auth/quota/tracking stack. This document is the
map; the contract itself lives at `/openapi.json` and `/developers`.

## Architecture

```
request → LSWeb.Plugs.ApiAuth ──────────────┐
  (Bearer/X-API-Key → SHA-256 lookup in     │
   SQLite; per-minute ETS rate limit;       │
   monthly SQLite quota; RFC 9457 errors)   │
                                            ▼
   /api/v1/* → LSWeb.ApiV1Controller ──→ LS.ApiData ──→ ClickHouse
   /mcp      → LSWeb.McpController  ───↗   (named columns, capped pages,
                                            escaped inputs, businesses table)
success only → LS.ApiKeys.record_usage_async (SQLite counter, monthly row)
             → LS.Umami.track_async          (server-side event)
```

Key decisions and why:

- **One consolidated data module** (`LS.ApiData`) feeds both surfaces, so
  REST and MCP can never disagree and the email-gating rule exists once
  per surface, pinned by tests.
- **Success-only, async usage recording**: an agent never pays for a miss
  (the single most trusted convention among agent-facing data APIs), and
  a slow SQLite write can never slow a response.
- **Quotas are calendar-monthly per plan** (free 1,000 / starter 5,000 /
  pro 25,000), shared across a user's keys; rate limits (30/60/120 per
  minute) are an ETS abuse guard, not billing.
- **Stateless MCP** (Streamable HTTP, JSON-RPC 2.0, no SSE, no sessions):
  valid per spec, works with Claude/Cursor/most clients via API-key
  headers, and needs zero new infrastructure. OAuth 2.1 + Dynamic Client
  Registration is Phase 2 and unlocks the ChatGPT connector surface.
- **Keys**: `ls_` + 24 random bytes; only the SHA-256 stored; one active
  key per user; revoke-and-recreate is rotation.

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

## Registry + directory submissions (the distribution work)

The MCP registries want a public GitHub repo that describes the server
(they index the repo, not your infrastructure). **Create a small public
repo `listsignal/listsignal-mcp`** containing:

1. `README.md` — what the server does, the three tools, the client
   config above, a link to https://listsignal.com/developers and the
   free-tier pitch (1,000 lookups/month). Include an example
   conversation ("find SaaS companies in France using HubSpot that are
   hiring"). Tool descriptions verbatim from `tools/list`.
2. `server.json` (below) for the official registry.
3. Optionally a 20-line stdio→HTTP shim (`npx mcp-remote
   https://listsignal.com/mcp`) so clients without native HTTP support
   can connect; `mcp-remote` is the standard bridge.

`server.json` for the official registry:

```json
{
  "$schema": "https://static.modelcontextprotocol.io/schemas/2025-09-29/server.schema.json",
  "name": "com.listsignal/listsignal",
  "description": "Live business intelligence for 14M+ online businesses: tech stacks, revenue estimates, hiring signals, contact data.",
  "repository": { "url": "https://github.com/listsignal/listsignal-mcp", "source": "github" },
  "version": "1.0.0",
  "remotes": [{ "type": "streamable-http", "url": "https://listsignal.com/mcp" }]
}
```

Submission steps, in ROI order:

1. **Official registry** (registry.modelcontextprotocol.io): install
   `mcp-publisher` CLI → `mcp-publisher login dns` proves the
   `com.listsignal` namespace via a TXT record on listsignal.com
   (`v=MCPv1; k=ed25519; p=<pubkey>` — the CLI generates it) →
   `mcp-publisher publish` with the server.json above. Downstream
   registries increasingly ingest from here.
2. **Smithery** (smithery.ai): sign in with GitHub, add the repo. Fill
   every manifest field — the quality score gates search placement.
3. **mcp.so, PulseMCP, Glama**: each has a Submit form; Glama
   auto-indexes GitHub, then claim the listing.
4. **cursor.directory** + an "Add to Cursor" deeplink badge in the README.
5. **awesome-mcp-servers** (github.com/punkpeye/awesome-mcp-servers): PR
   adding ListSignal under "Search & Data".
6. **Postman Public API Network**: import `/openapi.json`, publish the
   collection (free, keeps billing yours).
7. **APIs.guru**: PR with the OpenAPI URL; set-and-forget.
8. **Datarade** (via monda.ai): the B2B-data marketplace with real buyer
   intent; list ListSignal as a data product with the API as delivery.

## Phase 2 (not built, in order of unlock)

OAuth 2.1 + DCR (→ ChatGPT Apps + connector directory) → Stripe Billing
Meters per call above quota → x402 for walk-up agent payments.
