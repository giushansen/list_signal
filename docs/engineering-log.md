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

## 2026-08-27

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
