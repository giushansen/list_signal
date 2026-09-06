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
