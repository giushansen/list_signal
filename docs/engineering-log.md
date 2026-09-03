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
