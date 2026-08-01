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

## Tests — every bug and every feature, no exceptions

- **A bug is not fixed until a test would have caught it.** Write the failing
  test first if you can, but write it either way, in the same change as the
  fix. Name it after the failure it prevents, not the function it calls:
  `"WAF-walled businesses go to the browser even in the light tier"`, not
  `"test home_strategy/1"`. Put the incident (date + what it cost) in the test
  or describe block, so the next person changing that line learns why it is
  shaped that way. `test/ls/enrichment/regressions_test.exs` is the model.
- **A feature is not done until its behaviour is pinned by a test** — at
  minimum the happy path plus the way it degrades on hostile input.
- **Make the rule testable rather than testing around it.** If the logic that
  broke is buried in a function that needs the network, extract the decision
  as a pure function (`Agent.home_strategy/1`) and test that. Do not reach for
  mocks to test an unextracted rule.
- **Third-party data is hostile until proven otherwise.** Every value crossing
  a boundary — Shopify JSON, browser timings, HTML titles, CT-log names — gets
  a test for the empty, negative, oversized and control-character cases. Three
  separate production incidents came from one unescaped value reaching a
  TabSeparated insert and destroying an entire batch.
- **Guard the data, not just the code.** `test/ls/data_contract_test.exs` runs
  against a real ClickHouse and asserts that what the UI offers actually
  matches rows (it skips when no CH is reachable, so `mix test` stays green on
  a laptop). When you add a filter, a column or a page that promises a number,
  add its contract check there. Bugs that unit tests structurally cannot see —
  a query that compiles but matches nothing, an aggregate that silently
  returns a string, a view that drops MATERIALIZED columns — belong here.
- Green tests are not the goal; **a suite that fails when the product is wrong**
  is. If a test cannot fail, delete it.

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
