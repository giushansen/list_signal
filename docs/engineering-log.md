# Engineering log

The running history of why this system is shaped the way it is. Newest first.

**Read this before changing anything load-bearing.** Most entries exist because
something broke in production, and the fix is often counter-intuitive without
the incident behind it. Commit messages carry the detail; this file is the
index so you do not have to read the whole log to find the relevant one.

**How to use git as the record** (see also CLAUDE.md, "The git history is the
memory"):

```bash
git log --grep='outage'          # find incidents
git log -S'MemoryHigh'           # find when a value was introduced or changed
git log --follow -p <file>       # the full story of one file
git notes show <sha>             # follow-up notes attached after the fact
git log --notes                  # log with notes inline
```

`git notes` are used for things learned *after* a commit landed: whether a fix
actually held, what the measurement looked like a day later, what it broke.
Add one with `git notes add -m "..." <sha>` and push with
`git push origin refs/notes/commits`.

---

## 2026-09-09

**Architecture review and security audit, shipped as one series.** The
review ranked ten performance items and ten security items (the owner
dropped the Cloudflare load-balancer item and the release-tarball item);
everything below is measured on prod before the change, and the follow-up
numbers live in `git notes` on each commit.

**The public tech pages read an index, not a 193M-row scan.** Every
`/tech`, `/top`, `/compare`, directory and sitemap query ran
`http_tech LIKE '%X%'` over `domains_fast`, a view on `domains_current`
whose only sorting key is the domain. 24h of query_log before the change:
1,844 such queries, 29.5s average, 119s p95, 54,483 CPU-seconds and
7.6 TiB read; with the other `domains_fast` readers, 72% of all ClickHouse
read time on the customer-serving box. It is the shape of the 09-07
"Search unavailable" storm too. Migration 024 adds `ls.tech_index`, one
row per (technology, titled domain) sorted by (tech, rank, domain);
`LS.TechIndex` rebuilds it every six hours into a shadow table and swaps
it in (`EXCHANGE TABLES`), so readers never see it empty. The first fill on
prod took 5m05s and 13.2 GiB (146.8M rows, 292 technologies); a dry run of
the read side alone was 33s at 96 MB. Two meaning changes, deliberate and
documented in the migration: exact-token matching ("React" no longer counts
"React Router", which the directory already did), and directory counts and
per-tech distributions now count titled domains only, as the page's own
total always did. Names are bound as ClickHouse query parameters
(`{t:String}`), the first use of parameters in the codebase; `escape/1`
strips quotes and changes what was searched, parameters do not.
Commit: see `git log --grep='tech_index'`.

**Half the FINAL cost was two landing-page samples, and the hourly
`OPTIMIZE domains_current` cost more than every FINAL read together.**
query_log, 24h: 32,434 FINAL reads for 12,340s, of which 2,200 were
`sample_shopify_stores` / `sample_online_businesses` (3.3s and 3 GB each,
every 60s from LS.LandingCache) for 7,061s, 57% of the total. Those now
read without FINAL, dedupe their ten rows with `LIMIT 1 BY domain`, and
refresh every 30 minutes. `OPTIMIZE TABLE domains_current FINAL` ran 20
times a day at 566s each: 3.1 hours of merge CPU and a 33 GB rewrite per
hour, for a table nothing reads without FINAL that cares (point lookups
use FINAL; the tech index build reads FINAL once per six hours). Dropped
from `LS.Cluster.Optimizer`; `businesses` keeps its 94s hourly pass, which
holds duplicates at 0.07% (13,077 of 19.2M rows) and is what makes the
explorer's option lists safe to read without FINAL (0.7s/500 MB to
0.1s/80 MB each). CSV exports no longer aggregate every `biz_contact` row
with FINAL per export; the contact side is scoped to the exported domains.
Store point lookups (29,768/day at 102ms, `SELECT * ... FINAL WHERE
domain = ?`) were left alone: they are correct and cheap per call.

**Security audit findings and fixes.** In severity order: (S1) the users
database `/home/ls/ls_prod.db` and its WAL were mode 644 on the master;
now 600, with `UMask=0077` in the unit. (S2) Erlang distribution and epmd
listened on 0.0.0.0 on all 15 nodes behind nothing but iptables, which has
failed once before; `rel/env.sh.eex` binds both to the wg0 address. (S3)
the app queried ClickHouse as the passwordless `default` superuser (FILE,
URL, REMOTE, DROP with grant option); every call now goes through
`LS.Clickhouse.post/3` with the `ls_app` user (SELECT, INSERT, CREATE/DROP
TABLE, TRUNCATE, OPTIMIZE on `ls.*`, SELECT on `system.*`). (S4) no systemd
sandboxing; `devops/listsignal/systemd/30-hardening.conf` (ProtectSystem=
strict, PrivateTmp, NoNewPrivileges, no capabilities, address families
limited) applied by `apply_hardening.sh`. (S6) no Content-Security-Policy;
`LSWeb.Plugs.CSP` with a per-request nonce, enforced, every inline script
and handler converted. (S7) magic-link sends were unlimited; `LS.Throttle`
+ `LSWeb.MagicLink`, 5 per address per hour, 300 per hour in total. (S8)
request logs masked only "password"; keys, tokens, secrets and signatures
now filtered. (S9) `mix sobelow` in `make check`; it found one real bug, an
atom built from request input in SubscriptionController. Nothing here
slows a page or adds a step for a user.

**Node state left /tmp.** `LS.CacheSnapshot` wrote to `/tmp`, which
systemd-tmpfiles prunes after 10 days and which blocked `PrivateTmp`.
`LS.State.dir/0` resolves `/var/lib/listsignal` (`LS_STATE_DIR`), created
by the deploy script and the hardening script; the old file is read once
so the move does not cost a cold start.

---

## 2026-09-07

**Brand v1: the LS letter box is gone, the "Live list" mark is in.** The
logo is one frozen SVG path (`LSWeb.BrandComponents`, `@mark_path`) and
every favicon, tile, lockup and the share card is generated from the same
path and two colours by `docs/brand/gen_brand_assets.py`. The pack arrived
with `DARK = #0a0e17`; Tailwind `ls-dark` is `#080E1E`, so the assets were
regenerated before install (`brand_test.exs` pins the manifest colour to
the config). `head_icons/1` is shared by `public_root/1` and `root/1`.
Emails deliberately get no logo. Rules in `docs/brand/README.md`.

How it landed: the component, rollout and assets were still an uncommitted
working tree when a concurrent session ran `git add -A` and committed them
inside 1740612 ("An unknown /tech/<slug> is a free 404"), then pushed and
deployed. That commit therefore carries two unrelated changes, plus a stray
`listsignal-brand-pack.zip` removed in the next commit. `git notes show
1740612` has the detail. Lesson for concurrent sessions: stage by path,
never `git add -A`, when another session may have work in the tree.

**Compaction no longer reads the whole history table: the pass folds the
window into the compiled row.** The 09-06 finding stood: with
`domains_history` ordered by domain, `domain IN (touched)` for ~20K domains
hits all 47K granules, so every five-minute pass read 378M rows / 80 GB
(query_log 09-01 to 09-07: mean 218 s rising to 327 s with growth alone,
5-7 GB memory) and the 1190 s ceiling only changed which passes died: two
a day still hit the server's 6 GB cap, and "Ingestion rate: new businesses"
went out at 09-06 12:32 and 18:39 (the 18:00 hour also had three deploys
that SIGKILLed passes mid-flight). The fix is the compactor the 09-06 entry
described and did not build: `LS.Clickhouse.history_rows_sql/2` feeds the
unchanged `argMaxIf` fold from three sources under one UNION ALL, the
window's history rows (partition-pruned, ~1M rows read), each touched
business's newest compiled row replayed as two synthetic history rows (a
"verified" row at last_verified_at holding the 2xx columns, a "latest" row
at as_of holding the rest, status masked when it was 2xx), and the whole
history of the few hundred window domains that could newly qualify.
Measured alone on the box: a five-minute window (a real pass) runs in
32 s, reads 100M rows / 12.8 GB and peaks at 2.4 GB; the 13-minute
reference window runs in 141 s / 21 GB / 4.1 GB against the old form's
369 s / 82 GB on the same window under load. Output on that window: 9,633
rows against the old form's 9,612, every column equal on the 9,609 common
rows except ctl_subdomains ordering (same set, 0 set differences) and the
depth-side columns of rows the enrichment pass touched between the two
runs. Three things found on the way, each now a test: an
unscoped `NOT IN (SELECT domain FROM businesses)` is a 3.3 GB hash set on
a 6 GB server; the 1.5 GB spill setting, right for a rebuild, wrote 628
spill files for 36 MB and made a 44 s fold take 165 s; and blanking
`domain` on the verified row folded 2,082 of 9,633 businesses into an
empty-string group. FINAL on the businesses read is out: 33 s against
10 s on the count probe, and 966 s / 7 GB / killed on the server cap in the
full statement; the newest version is taken by an ordered LIMIT 1 BY, and
two versions sharing as_of with different content occur in 8 of 186,558
sampled domains.
Three rows in 9,612 are no longer refreshed by non-qualifying crawls: they
qualified only through a block flag a later browser render had cleared in
the compiled row, which the fold cannot see; they keep their row and
refresh on the next qualifying crawl. Remaining cost per pass:
the businesses read (all granules, because touched domains land in every
one) and the candidates' older history (85M rows, 23 s on the reference
window); the businesses half would shrink with a smaller
index_granularity, left for a measured follow-up. The 1190 s ceiling stays as headroom until a week of passes
shows the steady state. Live after the deploy: the first calm pass ran
64 s at 2.3 GB; the first catch-up pass over a 30-minute slice ran 208 s
at 5.4 GB, so the catch-up slice is now 600 s (three cheap passes 2 s
apart instead of one that can die on the cap). A five-minute live window
then still ran 336 s at 5.3 GB with 749 spill files: the server default
max_bytes_ratio_before_external_group_by = 0.5 spills past half the cap
whatever the byte threshold says (now 0 for the incremental form), and
that window had 989 candidates against the probe's 349, the pass's one
variable cost. Candidates are now only blocked or 4xx domains with no
classified crawl in the window (a classified 2xx crawl carries every
field; 121 and 31 on those two windows) and capped at 500 a pass.

## 2026-09-07

**Third abuse report, from a bank's CERT: one GET.** Shinhan Financial
Group's security centre reported, through Vultr, a "sophisticated attack"
from sg1 (139.180.191.194) at 17:05:10 KST. Our record: one HTTP GET to
the homepage of shinhangroup.com (106.249.55.48) at 08:05:10 UTC, HTTP 200,
1.3 s, with the declared ListSignalBot user agent, on a site whose
robots.txt allows every agent on `/`; the only other contact with that
network in 30 days was two fetches of shinhantrust.kr on 08-26. A bank's
intrusion detection treats any unknown crawler as an attack and the
report language is a template. Response: the whole Shinhan group is in
`LS.HTTP.NeverContact` (nine domains), and the reply to Vultr states the
single request with its evidence. The pattern across the three reports:
none was about volume; all were single fetches judged by a WAF or IDS on
identity. The honest UA, /bot page, robots.txt compliance and the
never-contact list are the defence; the exposure that remains is any
site whose security team reports on sight.

**Every worker-side revenue estimate has been blind to Tranco and Majestic.**
Found through google.com again: a forced recrawl at 07:00 UTC came back
"$10M-$100M" with an evidence trail of mail records and a cookie banner,
and the compactor took it as the newest estimate over the "$1B+" at 0.95
from 09-04. Workers hold a Tranco bloom (membership only) and no Majestic
table; `LS.Reputation.fill/1` adds the ranks on the master AFTER the
worker computed the estimate, and nothing re-estimated. Measured: of
101,243 ranked domains crawled in the last day with an estimate, 0 carry a
rank in `revenue_evidence`; in `businesses`, 533K of 1.15M ranked rows
still do, from crawls before the bloom change. Two fixes: the master's
Inserter re-runs the estimator after the fill (`Inserter.reestimate/1`),
and the compactor keeps the best-evidenced estimate (argMax on
`(revenue_confidence, enriched_at)`) instead of the newest, so a sparse
recrawl (rank and RDAP lookups served from cache, columns empty in that
row) can no longer replace a rich one. The ~616K degraded rows recover as
their domains are recompacted: history still holds the richer estimate.

**"Search unavailable" on a customer dashboard: a crawler walking invented
/tech/ slugs starved ClickHouse.** 05:15-05:40 UTC: 145 distinct /tech/<slug>
URLs in 25 minutes, slugs that are page titles, not technologies. Each
unknown slug fell through `canonical_tech_name/1` to a capitalised guess
and then `stores_by_tech_full_ilike/2`, a full scan of the 188M-row
`domains_fast` view, uncached because every slug is a new cache key, then
the six distribution queries. 415 concurrent scans of 18-25 minutes, load
average 120 on the 4-core master, every ClickHouse query timing out
(inserts, recrawl, DataCheck, and the explorer, whose failure message is
the one the owner saw). Killed 372 queries by hand, ran a 15-minute kill
loop, and shipped 1740612: a slug the tech directory does not know is a
404 that costs nothing, and the ILIKE fallback is deleted. Lesson, again:
a public page must never let a visitor-chosen string reach a full table
scan; the directory is the contract for what a URL may cost.

**Store pages read a `SELECT *` row by the inserter's column positions.**
`StoreController.parse_store/2` and `Tools.Lookup.parse_row/2` indexed the
domains_current row with `LS.Cluster.Inserter.columns/0`. That list gained
nine columns on 09-06/07 that domains_current does not have (the
email-auth, infrastructure, observation and provenance columns live on
domains_history and businesses only), so every field after dns_cname read
its neighbour: from the 09-06 morning deploy titles rendered as page lists
without an error, and once the shift reached classification_confidence a
float hit decode_html/1 (104 FunctionClauseErrors in ten minutes, found
by the other session at 04:5x UTC). Fix (e4d2fb0): `get_store/1` returns
maps keyed by domains_current's own column order, read once from
system.columns; cached lookup rows keep the inserter order they are built
in; a contract test reads a real row and asserts the title is text. Rule
for next time: a positional row must be zipped with the column list of the
query that produced it, never with a list that happens to look similar.

## 2026-09-06

**The dashboard's depth row is always on screen.** `/dashboard` hid the
whole Depth row (email, hiring, pricing, catalogue, SEO) until a business
model or tech was chosen, so the two filters that apply to every business,
Hiring and SEO, were unreachable from a fresh page. The row now always
shows; the type-specific controls still follow the chosen type
(`LSWeb.ExplorerLive.filter_shape/1`): catalogue and price band only for a
commerce model or platform, published pricing only for SaaS. Switching type
blanks the filters whose control just disappeared
(`prune_hidden_depth/1`), on every path that can change the type (form,
dropdown, tag removal, column clear), so a leftover "min products 10" can
never silently empty a SaaS list. The results table keeps its Products and
Avg $ columns; only the filter controls are gated. Pinned by
`test/ls_web/live/explorer_depth_toolbar_test.exs`.

**Provenance on every row.** `pipeline_version` (git sha at compile time),
`http_fingerprint` (script hosts, generator, server headers, size: the
evidence the detectors read, 2 KB, no raw HTML), `classification_source`
(`heuristic` or `ml:<head version>`) on `domains_history` and folded into
`businesses`; `pipeline_version` on enrichment rows (migration 023). The
motivation was tonight's google.com row: the wrong value could be traced
to a time and a table but the reasoning had to be reconstructed by hand.
`Clickhouse.compact_domains/1` recompacts a named list; the 98 Tranco
top-10K businesses still carrying a mis-linked Wikidata fact were
re-queued for a crawl so the plausibility guard applies through the
rewritten compactor's fast path (8ba7401, the other session's change,
measured 32 s per pass). Wikidata's Google entity (Q95) lists about.google
as its website and carries no revenue statement, so google.com has no
legitimate verified revenue; the estimate ($1B+, 5001+) is the value to
show, and the guard now blanks the mis-linked facts.

**Compaction has always read the entire domains_history table on every
pass, and no filter placement changes that.** Found while chasing why
passes failed continuously after the change-event fix: `system.query_log`
shows every incremental pass since at least 09-05 11:00 reading 376-399M
rows and 50-104 GB, and EXPLAIN shows "Condition: true, Granules
47494/47494" on domains_history. A pass touches 25K-97K domains (discovery
inserts ~5K domains a minute, so any window is tens of thousands of
random keys over 47K granules): no primary-key pruning is possible, and
measured on prod with the real INSERT into a throwaway table, a literal IN
list and an explicit PREWHERE read the same 109 GB (slower, in fact). The
pass alone takes 110-130s; it timed out at 290s, then 590s, only under
contention (concurrent probes, the /top cache warm-up every master deploy
fires, ClickHouse merges), which is the entire history of "compaction
timeouts on bad days", the 09-05 orphaned pass and today's two hours of
staleness. c0a366d moved the filter inside the subselect on the strength
of a 13-second measurement that was a `SELECT count() FROM (...)`
artefact (ClickHouse dropped the unreferenced aggregate columns); the
move is harmless but not a fix, and its commit message overstates it (see
its git note). What holds tonight: the touched set computed once
(3848f0a), the ceiling at 1190s under a 1200s client (c4b0b0b) so a
contended pass finishes instead of failing, and the observation rule at
insert time (`http_observed`, migration 022) because the SQL form over the
body snippet added IO to a pass that had none to spare. The structural fix
is a different compactor: fold the WINDOW's rows into the existing
`businesses` row (last non-empty wins per column) instead of
re-aggregating each touched domain's whole history, which reads the
current month's partition plus one businesses row per domain instead of
the whole table. Not done tonight.

**Change events audited: a stub crawl was recorded as "not present".**
Inventory: 3.8M events in 90 days (tech_removed 1.55M, tech_added 1.36M,
app_removed 502K, app_added 370K, started_hiring 34K). Persistence at 8
weeks (free metric, now in the weekly report as "Signal quality"):
tech_added 86.7%, tech_removed 83.5%, app_removed 84.8%, app_added 78.7%;
63,863 (domain, technology) pairs flapped 3+ times in 90 days (275K events,
7.4%). Sampled 2,000 "started showing" and 1,000 "stopped showing" events
with their crawl history: 13.3% of additions had a before-crawl that was a
stub (224 of 267 under 200 characters of visible text: bot wall served as
200, redirect shell, "Index of /", empty body) and 16.6% of removals had
an after-crawl of the same kind; 6% of additions had been seen in an
earlier crawl and vanished in between (detector variance across edges,
not fixable by this change). Re-fetching the 200-event subset with the
pipeline's own detectors: 84.3% present now; 66.0% both present now AND
absent in a healthy before-crawl (+/- 6.7pp). Fix: `Clickhouse.observed_sql/1`,
one predicate for "this crawl observed the site" (2xx-3xx, not blocked,
200+ characters of visible text, no bot-wall title), used by record_signals,
the signals backfill and the compactor's http_tech/http_apps fold. On the
sampled domains' histories it removes 30.5% of tech events and 40.8% of
flapping pairs while suppressing 0 of the 1,578 clean adoptions. A note on
method: an LLM reading a text fetch cannot verify technographics (WebFetch
strips the script tags the evidence lives in; a Sonnet spot-check called 32
of 40 events "absent" on that basis), so Eval 1 uses the pipeline's own
detectors on a fresh fetch, which cannot see the detector's own systematic
errors; the spot-check did surface two: a WooCommerce plugin and Odoo
detected on Shopify stores (loose signatures, see the counts in the commit).

**Subdomains are now a union, and the depth pass estimates revenue with
everything it knows.** `businesses.ctl_subdomains` used to be the newest
certificate's SAN list; it is now the distinct union over every certificate
in `domains_history` plus the last 90 days of `ctl_sightings` (the ones the
7-day gate suppressed), capped at 300 names, with `ctl_subdomain_count`
following. The expression is written twice in the compactor on purpose: an
alias column would break the positional INSERT list, and a WITH clause is
stripped by the contract test that executes the SELECT alone.

**More DNS that says how big the IT is.** `LS.DNS.Infra`: reverse DNS of the
web host (cached per IP, 300K cap) and the Microsoft records that only exist
with Exchange, Teams federation or Entra/Intune enrolment
(`_autodiscover._tcp`, `_sipfederationtls._tcp` SRV, `enterpriseregistration`
CNAME; MX domains only). Columns `dns_ptr`, `dns_ms_enterprise` (migration
021). The estimator gained `signal_ms_enterprise`, `signal_hosting_ptr`,
`signal_site_size`, `signal_depth` (catalog, hiring).

**Sitemap snapshot.** `LS.Enrichment.Sitemap` reads the sitemap named by the
robots.txt we already fetch (else `/sitemap.xml`), samples up to three child
sitemaps of an index and extrapolates: URL count, product and blog URL
counts, child count, newest lastmod, and a 64-bit simhash of the URL paths
so a restructure becomes a change signal. Full tier only, at most four
requests per business. `sitemap_*` columns on `biz_enrichment` and
`businesses`.

**Depth-pass revenue estimate.** The queue item now carries the 27 columns
the estimator reads (`Clickhouse.estimator_columns/0`), and
`Agent.depth_estimate/2` re-runs the estimator with apps, catalog, sitemap
and jobs on top. Stored as `depth_estimated_*` on `biz_enrichment`; the
compactor prefers it over the discovery-time estimate when present (fold
aliases `d_*`, because an alias equal to a source column inside another
argMaxIf condition is a nested aggregate to ClickHouse, Code 184).

**The classifier sees structure.** `LS.ML.Features.hint/1` renders
platform, apps, mail setup, catalog, jobs and page counts as a short
fixed-vocabulary sentence appended to the text MiniLM embeds, in the
pipeline and in the training embedding script alike, so the head is trained
and served on one shape. Head v3 is trained on the distill v3 teacher
labels once they are complete (in progress, `analysis/distill/`).

**robots.txt cost, measured after 6 hours fleet-wide:** 5,016 of 512,781
HTTP attempts refused (0.98%); 1,250 of the 5,408 refused domains were
already known businesses. Sites that allow only Googlebot are correctly
refused: the group for `*` applies to a declared bot.

**Discovery is gated to one fetch per 7 days, and what it gates is kept.**
`LS.Cluster.CrawlDedup` moved from two 3.5-day blooms (guaranteed 3.5, at
most 7) to eight daily windows of 10M entries (~96MB): a crawled domain is
suppressed for 7 to 8 days, and the recrawl scheduler, which IS the 7-day
schedule, bypasses the gate with `enqueue(data, force: true)`. A suppressed
certificate sighting is no longer discarded: issuer, subdomain count and
subdomains go to the new `ctl_sightings` table (migration 020, 90-day TTL)
from an ETS buffer the CrawlDedup GenServer flushes every 30s. Deliberately
not `domains_history`: `domains_current` is newest-row-wins on it and a
certificate-only row would blank a domain's DNS and HTTP columns. For the
record, pipeline 2 (depth enrichment: catalog, contacts, careers, pricing)
re-runs a business every 30 days (`businesses_needing_enrichment`, "NOT IN
biz_enrichment last 30 DAY"), while pipeline 1's recrawl of the homepage is
7 days for digital business models and 30 for the rest.

**DMARC, BIMI and DKIM are looked up; the DMARC revenue signal had never
fired.** `LS.DNS.EmailAuth` runs in the discovery DNS stage for domains
with MX only: one `_dmarc` query, BIMI only when DMARC enforces, at most two
DKIM selector probes chosen from the MX provider. New columns `dns_dmarc`,
`dns_bimi`, `dns_dkim` on `domains_history` and `businesses`. The
estimator's `signal_dmarc_policy` had scanned the apex TXT, where DMARC
never lives, so it voted "micro" for every domain since it was written; it
now reads the column, and BIMI (trademark + VMC) and DKIM (Microsoft 365
selectors, marketing platforms) are new voters.

**Shopify apps beyond the signature list, and what kind of store.**
`AppDetector` reads theme-app-extension handles generically from
`cdn.shopify.com/extensions/<id>/<handle>-<version>/` (every extension-based
app, not only the 135 domains on the list), app-proxy pages (`/apps/...`),
and HubSpot hub loaders (Forms, CTA, Chat, Meetings, Ads, CMS). The depth
pass (`Agent.deep_apps/5`) scans the homepage, the secondary pages and the
first product page of Shopify stores, and reads theme, theme store id,
currency, locale count and a Plus hint from `window.Shopify`
(`LS.Enrichment.ShopifyStore`). `biz_enrichment.apps_deep` is unioned into
`businesses.http_apps` by the compactor; `shop_*` are new columns.

**google.com was a "<$1M, 51-500 people" company.** Several Wikidata items
list google.com as their official website (a school founded in 1544 among
them; Google LLC itself was not in the fetched set), the compactor's
`LIMIT 1 BY domain, fact, source` picked one arbitrarily, and the store page
prefers a verified fact over the estimate. Two fixes: among same-source
candidates the largest value now wins (a subsidiary is never bigger than
its parent), and a verified fact that contradicts a Tranco top-10K rank
(revenue under $10M, headcount under 50) is blanked at compaction. Both
apply to rows as they are recompacted; run `Compactor.rebuild_sharded/1`
to sweep the existing table. `data_contract_test` pins the invariant.

**ClickHouse's own log writer was wedged for 15 days, burning one core.**
The 08-22 03:23 UTC disk-full event (the backup-dir pile-up cleaned on
08-24) hit ClickHouse's main log stream mid-line. The disk was freed, the
stream never recovered: every message after that threw "File access error"
inside the log channel and the exception plus a 25-frame stack trace went to
stderr, so journald received millions of lines per minute and answered with
"Suppressed ~6M messages / 30s". sar shows the cost: system CPU 6-7% and
idle 51-61% on 08-20/21, then system 21-22% and idle 15-24% every day
through 09-06; journald alone sat at 60-93% of a core, and the 4G journal
only held ~35h of history because it was full of this noise. Nothing in the
app saw it: the file was writable, ClickHouse answered queries, the site
was up. Found on 09-06 while reading the restart journal by eye. Fixed by
`systemctl restart clickhouse-server` at 04:42 UTC (main log writes again,
zero suppressed messages after). Prevention still owed: a Sentinel check
that the ClickHouse main log mtime moves while the server runs, or that
journald reports no suppression, so a wedged logger is an email and not a
15-day silent tax. Unrelated to the 02:30 restart below, which is memory
inside the BEAM.

**The master's daily restart, root-caused and removed: cache eviction copied
the 5M-row CT cache into every poller worker at once.** The forensics trap
(watch-zone snapshots to `ops_memory_snapshots`, shipped 09-05) caught the
09-06 02:30 spike: `processes` went 429 MB to 9,894 MB in 38 s, held by 14
anonymous boot-time processes at 200-620 MB each, with `ctl_cache` at
exactly 5,000,000 rows. Those pids are `LS.CTL.Poller`'s spawn_link'd
workers, and `LS.Cache.evict_to/3` did `:ets.tab2list` + `Enum.sort_by` on
the whole table inside whichever process inserted the entry that crossed
the cap; ~28 workers cross it within the same second. The snapshot
timeline shows the sawtooth: the 6-hourly TTL sweep trims the cache to
~1.5M, inflow refills it at ~400K/h, and whenever it reaches 5M before the
next sweep the BEAM blows up (09-03 19:19 at 5.0M rows, 09-06 02:30 at 5.0M
rows; 14 watchdog restarts since 08-21). Nothing in ClickHouse: no query in
either spike window returned more than 5 MB. Fix (commit below): eviction
samples 20K rows for the age cutoff, deletes with `:ets.select_delete`
(inside ETS, nothing copied), and is single-flight per table; ties at the
cutoff second are trimmed by count so a burst cannot empty a table.
`cache_bounds_test.exs` runs a 400K-row eviction under a 16 MB heap cap.
Same change: `CacheSnapshot` reads the CT cache with a limited select
instead of tab2list + take (its GenServer sat at 292 MB, 825 MB during the
spike), forensics now records where each top process is executing
(`at`), and the disk early warning is sustained-only (two ticks) because
ClickHouse merges of the 59 GB history table legitimately borrow tens of GB
for 10-20 minutes several times a day.

**robots.txt is honoured, fleet-wide.** `/bot` promised "add a Disallow and
ListSignalBot will not visit again" while no code read robots.txt.
`LS.HTTP.Robots` (RFC 9309 groups, longest-match, wildcards, 24h cache,
hostile-input bounded) gates `Client.fetch/3`, so discovery, recrawl,
secondary pages, ATS boards and `fetch_url` all consult it, and
`Browser.render/2` refuses too: the camoufox lane is not a way around an
opt-out. A refusal is recorded as `http_error = robots_disallow`, which
`stale_domains` and both enrichment lanes exclude. Cost: one small extra
request per crawled domain-day, through the same politeness limiter.

**Disk: master alerts were merges, opsbloc was full.** Master sits at 69%
of 361 GB between merges and 78-81% during them; the alert fired per merge.
Real waste found: 12.4 GB of ClickHouse system logs disabled on 07-26 but
never dropped (`trace_log` 8.2 GB), 8 x 7.3 GB product archives (58 GB;
retention was chosen when they were 1.6 GB), and opsbloc holding every
product archive twice (`backup.sh` ships to `/root/ls-backups`,
`offsite_backup.sh` to `/root/listsignal-offsite`) until its 120 GB disk hit
100% and Umami's Postgres dropped into recovery. Retention cut to 4 local /
3 offsite, the duplicate shipper retired, and the laptop pull
(`devops/listsignal/laptop/pull_backup.py`) is now the deep copy.

## 2026-09-04

**Second Vultr abuse report in a week; crawler identity overhauled.** Report
named www.xayann-services.com: two requests to `/`, 6h13m apart, from ny1
and dal2, both 503'd by the WAF, flagged as "Honey Pot verification / Rogue
User-Agent identification". Matched our records to the second. Root cause
is structural, not volume: (1) the HTTP lane rotated six fake desktop
Chrome/Firefox UAs from a client that cannot pass a JS challenge, which is
the exact fingerprint of malware to a WAF; (2) `stale_domains` re-selected
WAF-blocked domains on schedule forever — 2.64M domains sat at 403/429/503
(2.05M/388K/206K), each re-hit from a rotating IP; (3) 217K domains were
crawled twice ~6h apart on 09-03 alone (separate follow-up: the CTL dedup
cache holds ~1h of inflow at 1,400/s, so multi-log cert entries re-enqueue;
not fixed in this change). Fixes shipped together: honest
`ListSignalBot/1.0 (+https://listsignal.com/bot)` UA with a public
transparency/opt-out page at /bot; blocked statuses excluded from plain-HTTP
recrawl (the camoufox lane, a real browser that passes challenges, keeps
them); and `LS.HTTP.NeverContact`, a permanent blocklist of abuse-reporting
domains enforced in `Client.fetch/3` and `Browser.render/2` — the two choke
points every engine goes through. Expected trade-off: some sites 403 a
declared bot that tolerated a fake browser; those now exit the rotation
after one clean refusal, which is the defensible behavior. Measure the
200-rate before/after and log it here.

**Same day, the duplicate-crawl waste got its fix: `LS.Cluster.CrawlDedup`.**
Two rotating 50M-entry blooms (114MB total, 3.5-day rotation, suppression
window 3.5-7 days) consulted by `WorkQueue.enqueue/1`; entries expire by
day 7 so the weekly recrawl tier always passes, and the requeue path
bypasses it by construction (direct ETS insert). Fails open, backfills the
last 24h from ClickHouse in 16 shards after every restart. Also: 503 joined
401/403 as a browser-lane wall (`enrichment_lane_filter`,
`Agent.needs_browser?`), while 429 stayed OUT of every exclusion on the
2026-08-02 lesson: rate limiting is patience, not a wall, and the
regression suite caught exactly that mistake in review before it shipped —
the first draft wrongly excluded 429 from recrawl and routed it to the
browser lane, which would have silently lost 388K domains and drowned the
camoufox bucket again.

## 2026-08-31

**`NodeResources.local/0` forked `systemctl` twice per erpc poll, tipping
already-thrashing workers into false "unmonitored" alerts.** `restart_info`
was called once per field (`:result`, `:count`), each shelling out to
`systemctl show` separately, even though one call returns both. Forking is
the slow path under real memory pressure (swap-in page faults), so the
redundant fork made the master's 3s `erpc` timeout more likely to trip on a
node that was already thrashing — turning one real `mem_pressure` event
into a second, confusing "node unmonitored" alert. `unmonitored` and
`mem_pressure` alerts clustered in the same windows all day (13:34-19:05,
22:20-01:50). Fixed to one `systemctl` call
(`lib/ls/ops/node_resources.ex`); deployed fleet-wide.

**Real thrashing, not a leak: dual-profile enrichment concurrency was tuned
against CPU, never against memory.** chi1 measured 4.5GB in swap on a 3.8GB
box (more swapped than the box physically has). No single runaway process —
BEAM 752MB, camoufox sidecar 220MB, unbound 268MB — the swap comes from
bursty `LS_ENRICH_CONCURRENCY=10` (2026-08 tuning was against load: 12
caused load 13-15, never re-measured against RAM after the camoufox sidecar
landed, exactly as flagged in `fleet.conf`'s own comment). Cut to 6.
Post-cut throughput held at 20,650/h, above the prior 24h average of
19,895/h — free win, no backlog cost.

**`apply_profile.sh` silently skipped 4 of 9 dual nodes for weeks.**
sg2/par2/dal1/dal2 carry inline `# 2026-08-25: ...` history notes in
`fleet.conf` after their profile field. The fd3 read never stripped
trailing comments, so `$profile` picked up the whole comment text,
`profile_env` hit its `unknown profile` branch, and `|| continue` skipped
the node — with no error surfaced anywhere. Those 4 had been stuck at
`LS_ENRICH_CONCURRENCY=12` (the value already known to cause CPU load
13-15) through every prior "tuned to 10" change. Found via a dry run.
Fixed by stripping `#.*` before the read (devops repo,
`listsignal/apply_profile.sh`).

**Backfilled the cut capacity: chi3/ny3 resized 1c/2G -> 2c/4G, moved to
the dual profile.** syd1 and sg1 held back — syd1 has a documented chronic
outbound TLS/RDAP degradation unrelated to compute, a weak multiplier for
enrichment specifically; sg1 is healthy but held pending a longer post-cut
throughput read before spending more.

## 2026-08-27

**Common Crawl probe: not worth a pipeline for our population.** Sampled 150
businesses with MX but no email (population 3.55M) against CC-MAIN-2026-34
plus two older indexes. CC covers only 24% of them: our edge is precisely the
fresh, small tail CC does not visit. Funnel: 150 sampled, 37 in CC, 13 with a
contact-like page, 5 yielding an email we lack (3.3%). Careers, team, login
and pricing pages: 0-2 of 150. First-crawl date as an age substitute for the
2.85M businesses on registries that publish no creation date: 28% get a bound
but three quarters of those are 2026 first-crawls we already know from CT, so
only ~7.6% gain a real age. Better levers: crawl /about ourselves for the
no-email subset (we reach 100% of them, CC reaches 24%), and use first
certificate date from CT history for age on .de/.it/.ch/.com.au.

**RDAP: failures were cached as done for 90 days.** 47.9% of businesses had no
creation date. 3.74M of the 7.34M missing are on TLDs where RDAP answers
(.com sat at 63.5%) and were frozen by the worker error branch writing to the
90-day done-cache on ANY failure; recrawls saw a hit and never retried. Fixed;
the gap now closes with each recrawl wave. The other 2.85M are structural:
DENIC, .it, .ch, .com.au publish no date via RDAP, and no pipeline change can
conjure one.

**Country attribution was 62.8% correct and is now 76.7%, with 2.15M
unsupportable labels withdrawn.** A customer found a Nashville nurse-triage
service (`intellatriage.com`) in a list of French companies. Three more
followed: `eapc-us.com`, `geteino.com` and `tryeino.com`, all English-language
with no legal page, French only because they sit on OVH. And `knowunity.fr`,
a Berlin company carrying German VAT `DE326705352` on its own site.

Measured on 566 live generic-TLD sites, scored against evidence the businesses
print about themselves (VAT and registration numbers, schema.org
`addressCountry`, dialling prefixes):

| signal | fired | correct | precision |
|---|---:|---:|---:|
| page evidence (cross-validated) | 35 | 30 | 85.7% |
| language to country | 19 | 14 | 73.7% |
| BGP with the old infra filter | 35 | 20 | 57.1% |
| the whole rule as it stood | 43 | 27 | 62.8% |

Two results overturned the assumptions the module was built on. **Language is
more accurate than BGP**, so it was not demoted below it, contrary to the
advice given before measuring. And the BGP failures were nearly all ordinary
hosting the `@infra_asn_markers` list did not name: Hostinger alone produced
7 wrong answers, with GoDaddy, Hetzner, dogado and eTOP behind it. GoDaddy
also failed to match at all, because ASN org strings hyphenate inconsistently
and `AS-26496-GO-DADDY-COM-LLC` does not contain `godaddy`. Punctuation is now
stripped before matching, in both implementations.

Also removed: `es`, `pt`, `ar`, `hi`, `bn`, `ta`, `te` and `sco` from the
language map. Each named ONE country for a language spoken across many, so
Spanish named Spain for a Mexican business. Scored with page evidence withheld
so it is never measured against itself, the rules alone went from 62.8% to
**76.7%** and halved the wrong rows, 16 to 7.

**The RDAP tier had been dead since it was written.** The crawler fetches the
registrant country (`LS.RDAP.Client.find_registrant_country/1`) and `infer/5`
accepts it, but it was never given a column, and the compactor recomputes
`inferred_country` from stored columns on every pass via `sql_expr/4`, which
had no RDAP argument. So the value was used once at crawl time and discarded
within minutes. Migration 018 gives it a column, along with
`http_country_evidence` from the new `LS.HTTP.CountryEvidence`. The contract
test that keeps the Elixir and SQL paths in lockstep was itself passing
`_rdap` and dropping it, so the tier was untested on the SQL side too; it now
passes every input to both.

Fleet-wide projection over 13.0M live businesses: 9.34M labelled before, 7.19M
after, **2,150,661 withdrawn** and 118,776 reassigned. Coverage falls from
71.8% to 55.3% and that is the point, the same trade made on 2026-08-06.
Coverage returns as recrawl fills the two new columns.


**Workers hold Tranco as a bloom filter.** `tranco_ranks` was 402MB of a 675MB
BEAM on nodes with 1,968MB total, and it existed to answer one question:
`LS.HTTP.DomainFilter` asks whether a domain is ranked and bypasses the
TLD/MX/SPF heuristics when it is (worth ~150K domains per 1.5 days). Workers
now keep a 4.9MB bloom filter for that test and the master fills `tranco_rank`
from its own copy, as it already does for `majestic_rank`. Verified on prod:
zero false negatives across 300 sampled ranked domains, 1.1% false positives,
BEAM 675MB to 236MB. Bloom filters have no false negatives, so the only cost
is crawling a domain we would have skipped, which is the direction the filter
already errs in. Both Tranco and Majestic remain on every `businesses` record
and both still drive the enrichment tier and ordering: Tranco measures
traffic, Majestic measures link authority.

**Public copy reads as human-written, enforced by a test.** Em dashes, en
dashes, curly quotes and ellipsis characters removed from every page template
and every string that goes out by email. `test/ls_web/human_copy_test.exs`
fails if they come back. Style notes in a document get forgotten by the next
session; a failing test does not.

**Master outage 07:30-07:46 local, the fourth of its kind.** The BEAM's
anonymous memory passed the 6G cgroup soft limit; with `MemorySwapMax=0` the
kernel had nothing to reclaim, so it throttled the process until it stalled
for 2.5 minutes with no log output at all. Finch's ClickHouse pool exhausted,
Erlang `global` disconnected all 14 workers, and the watchdog restarted it.
Two fixes: background ClickHouse work (compaction, `OPTIMIZE FINAL`, signal
recording) moved to its own small `LS.Finch.CHBackground` pool so a 110-second
compaction can never hold connections the web tier needs; and a watchdog
restart is now a **critical alert**, because the previous three occurrences
were silent and silence read as uptime. Limits raised to 9G/11G to match the
post-CT-v2 working set. See `listsignal-master-stall-outages` in memory and
`devops/listsignal/systemd/20-memory.conf`.

**Reference data lives once.** Workers loaded Tranco (403MB) *and* Majestic
(101MB) into ETS on nodes with 1,968MB total. Majestic is only ever an output
column, so the master backfills it (`LS.Reputation.fill/1`); Tranco stays on
workers because `LS.HTTP.DomainFilter` uses it as a crawl bypass worth ~150K
domains per 1.5 days. Measured alternative for Tranco membership: a bloom
filter is 4.9MB versus 402MB, and 0.09us versus 3.16us on misses.

**Crawler caches bounded by size, not only TTL.** `LS.Cache`'s http/bgp/rdap
tables were bounded only by their TTL (14/14/90 days), so nothing was evicted
until an entry was two weeks old: ~1.7GB of ETS on 2-4GB nodes. Now capped at
a share of each node's own RAM with oldest-first eviction, which keeps the
recent window politeness depends on.

## 2026-08-26

**Monitoring covered 2 of 14 nodes and nobody could tell.** `LS.Ops.NodeResources`
was `:undef` on every worker that had been restarted but never re-deployed, so
`Metrics.node_resources/0` silently dropped them. `Metrics.unmonitored_nodes/0`
now alerts on the blind spot itself. **Restarting is not deploying.**

**Wikidata verification had been dead for days.** `year/1` took the first four
characters of any date and `String.to_integer/1` raised on `"unknown value"`,
aborting the whole source after 22 seconds while every other source reported ok.

## 2026-08-25

**CT ingestion v2.** Precertificates were skipped entirely (most CAs, Let's
Encrypt included, log nothing else), only the first SAN of each certificate was
read, and the Static CT API was unsupported. Inflow went from ~210 to ~1,400
domains/second. Sources are now derived from Chrome's log list and reconciled
every 6 hours rather than hand-maintained.

**Page caches persist across deploys** (`LS.CacheSnapshot`), because caching
cut ClickHouse read CPU from 13.7 cores to 0.86 and thereby made every restart
a cold start. Boot order versus `LSWeb.Endpoint` is load-bearing and pinned by
a test.
