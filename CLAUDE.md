# Working agreement for Claude sessions on ListSignal

These rules apply to every session in this repo. They are the owner's standing
instructions — follow them without being asked again.

## Code

- **Document as you go.** Every module gets a `@moduledoc`; every public
  function that isn't self-evident gets a `@doc` (and a `@spec` where it
  clarifies). Explain *why*, not *what* — especially for anything that exists
  because of a past incident.
- **Refresh the docs whenever code changes.** Run `mix docs` and update
  `docs/architecture.md` + the relevant README in the same change, not later.
- **Short, clear, safe, fast — in that order of tie-breaking.** Someone new
  must be able to read it. Prefer deleting code over adding it. No cleverness
  that needs a paragraph to justify.
- **Report meaning changes.** If a change alters behaviour, semantics, or an
  invariant, say so explicitly in the summary — don't bury it in a diff.
- **Never commit unless asked.** Show the full diff and wait for approval.
  Commits end with the `Co-Authored-By` trailer.
- Run `mix test` (and `mix compile --warnings-as-errors`) before presenting work.

## Crawling — non-negotiable

- **The politeness cache and per-IP rate limiter stay.** They protect our IPs
  from being blacklisted, which is an existential risk for this business.
  Never remove or loosen them to gain throughput. If a cache causes a bug
  (e.g. blanking data), fix the *cache semantics* — make it return data like
  `LS.Cache.bgp_lookup/1` does — never by disabling politeness.
- Browser (camoufox) work: **max 3 concurrent per node**, same per-IP limiter
  as the HTTP pipeline, and it must look like a real human client.
- One deploy at a time, one node at a time. **Check for a concurrent deployer
  first**: `ps aux | grep deploy_listsignal`.

## Data

- **Never let a writer blank another writer's data.** `domains_current` and
  `businesses` are newest-row-wins; a partial row erases good data. Pipelines
  write only their own tables/columns, and the compactor coalesces
  "last non-empty per signal unit".
- ClickHouse facts worth remembering (measured on prod, 2026-07):
  sparse columns are ~free (191:1 compression), `ALTER ADD COLUMN` is 0.056s,
  but a JOIN costs ~9× a single-table scan. So: **wide tables for 1:1 scalars,
  child tables only for genuine 1:many lists.**
- **Back up before schema changes**: `/home/ls/backup.sh all` on the master.

## Ops

- Prod master: `root@45.63.7.58`. ClickHouse is localhost-only; reach it via
  the SSH tunnel or `clickhouse-client` on the box.
- Metabase (prod): `https://metabase.listsignal.com:8443`, secrets in
  `/root/.listsignal-secrets`.
- Query source of truth lives in `metabase/queries/*.sql` — iterate in the
  Metabase editor, then paste back into the repo file.
- The master is a shared box (ClickHouse 7G cap + app 4G cap + Metabase 4G).
  Heavy migrations must be memory-bounded (shard the aggregation) or they get
  OOM-killed.
