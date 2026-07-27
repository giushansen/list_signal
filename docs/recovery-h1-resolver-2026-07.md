# Recovery plan — h1 resolver incident (2026-07-04 → 2026-07-26)

**Status: plan only. Nothing in here has been run.**

The bleeding is stopped (h1 is fenced at the master's firewall, see "Fencing"
below). This document costs out how to repair the data.

## What happened

**Root cause (confirmed on the box 2026-07-26): h1's Tailscale node key
expired.**

```
Jul 04 20:53:41 ls-h1 tailscaled: Switching ipn state Running -> NeedsLogin
```

Tailscale had written `/etc/resolv.conf` pointing at its MagicDNS resolver
(`100.100.100.100`) and does **not** revert it on logout. Worse, the file
carried the **immutable flag** (`chattr +i`), so the dead config was frozen in
place — nothing could rewrite it, not even Tailscale itself. Every OS-level
lookup on h1 failed from that minute on.

`LS.DNS.Resolver` pins `nameservers: [{{127,0,0,1},53}]` so DNS enrichment kept
working against Unbound, while `LS.HTTP.Client` (Mint), `LS.BGP.Resolver`
(`whois.cymru.com`) and RDAP all resolve through the OS and therefore failed.
h1 kept claiming batches and writing rows with DNS data and nothing else.

**Fixed 2026-07-26**: cleared the immutable flag, wrote the same resolv.conf the
healthy workers use (`127.0.0.1` + Cloudflare fallback), re-applied `chattr +i`
so Tailscale can never clobber it again, and set `tailscale set
--accept-dns=false`. Verified end to end on h1: HTTPS 200, Team Cymru whois:43
returning ASN data, RDAP 200. Back in the cluster and indistinguishable from
its peers (bgp 0.915, rdap 0.469, guard metric 1.000, zero nxdomain).

Tailscale itself is still **logged out** on h1 — it needs an interactive
re-auth. That no longer affects enrichment, but it's why the box vanished from
the tailnet. (h1 is reachable on the LAN at **192.168.1.73** and
**192.168.1.74** — it answers on both NICs.)

Because `domains_current` is `ReplacingMergeTree(enriched_at) ORDER BY domain`,
the newest row wins — so an h1 row **replaced** good data whenever it re-touched
a domain. h1 also ran ~12× its normal volume (failing is fast, and it's a
16-core box), taking ~64% of all work.

Fixed in code (not yet deployed) by `pin_vm_resolver/0` in `LS.Application`,
which points the whole BEAM at Unbound so this split-brain can't recur, plus a
quality guard in `LS.Cluster.Inserter` that quarantines a worker whose
enrichment collapses.

## Blast radius

Measured over the full incident window (`enriched_at >= '2026-07-04'`), where
"hollow" = `http_status IS NULL AND bgp_asn_number='' AND rdap_registrar=''`
and the domain's newest row is from h1:

| Tier | Domains | What it means |
|---|---:|---|
| **1. Regressed** | **3,144,505** | Had real enrichment, now hollow. **We destroyed data here.** |
| ↳ of which Tranco-ranked | 235,965 | Site-visible, SEO-relevant. Highest priority. |
| 2. Ranked, never enriched | 241,465 | h1 got there first; ranked so worth crawling |
| 3. Unranked, never enriched | 41,919,710 | Long tail; most would be low-value anyway |
| **Total hollow from h1** | **45,305,680** | |

> Earlier in the investigation I quoted 933K regressed. That used a narrower
> 21-day window and counted only `http_status IS NOT NULL` as "good".
> **3,144,505 is the correct figure** — full incident window, and BGP/RDAP
> count as real enrichment.

Site impact today: affected pages render with an empty `<title>` and no BGP or
RDAP, e.g. `[STORE] Rendering glossier.com — tech:4 bgp: rdap:`.

## Why not just restore from history

The good rows still exist — `enrichments` is append-only and nothing was
deleted. So an `INSERT … SELECT` could copy each domain's last-good row back
with `enriched_at = now()`, and it would win the ReplacingMergeTree.

**Rejected as the primary fix**, because a restored row looks freshly enriched
to `LS.Recrawl.Scheduler` (which selects on `enriched_at` age), so it would
pin up-to-3-week-old data in place for another 7–30 days. It also can't recover
tier 2/3, which never had good data.

Worth doing **only** as a stopgap if the site needs to look right within
minutes rather than hours — and if so, it must be paired with an explicit
re-enqueue so the stale data gets refreshed.

## Recommended: targeted re-enqueue

Push affected domains back through the normal pipeline. Healthy workers
re-enrich them properly and the data is fresh, not stale.

The scheduler already does exactly this (`recrawl/scheduler.ex:82-93`):

```elixir
LS.Cluster.WorkQueue.enqueue(%{ctl_domain: domain, source: :recrawl})
```

Use that key. `:ctl_domain` is what the worker pipeline reads
(`worker_agent.ex:256`); a recrawl item missing it is what crash-looped every
worker once before.

### Costing

Measured drain is **3,277 items/min ≈ 196,600/hour**, and CT-log inflow
(~3,286/min) already consumes almost all of it. So added work roughly *doubles*
the wall-clock unless CT ingestion is paused.

| Phase | Domains | Queue-hours | Realistic (CT running) |
|---|---:|---:|---:|
| 1. Tier-1 ranked | 235,965 | 1.2 h | ~2–3 h |
| 2. Tier-1 remainder | 2,908,540 | 14.8 h | ~1.5 days |
| 3. Tier-2 ranked | 241,465 | 1.2 h | ~2–3 h |
| 4. Tier-3 long tail | 41,919,710 | 213 h | **~9–18 days** |

**Do phases 1–3 (~3.4M domains). Skip phase 4** — let the natural recrawl
cycle absorb it. h1's rows are dated Jul 4–26, so the 7-day (digital) and
30-day (rest) rules already bring them up between Jul 11 and Aug 25 without
any intervention. Forcing it would stall new CT discovery for over a week.

### Constraints

- `@max_queue_size` is **1,000,000** (`work_queue.ex:31`) and the queue sits at
  ~8K. Enqueue in batches of **≤150K**, waiting for drain between batches —
  `enqueue/1` returns `:queue_full` and the scheduler aborts the rest.
- `@ttl_ms` is **24h** (`work_queue.ex:33`). Anything not drained within a day
  is silently dropped, so never enqueue more than ~4h of drain at once.
- Run phases sequentially and verify after each; do not queue all of tier 1 up
  front.

### Verification after each phase

```sql
-- should trend to 0 for the batch just processed
SELECT count() FROM (
  SELECT domain,
         argMax(worker, enriched_at) AS nw,
         argMax(http_status IS NULL AND bgp_asn_number='' AND rdap_registrar='',
                enriched_at) AS hollow
  FROM enrichments WHERE enriched_at >= '2026-07-04'
  GROUP BY domain HAVING hollow AND nw LIKE '%h1%'
)
```

Also watch Metabase query 05 (per-worker health) and 08 (stage failure rates)
— `bgp_empty_of_crawled` must stay at 0.000.

## Capacity problem this exposed — read before recovering

h1's instant failures were **inflating the apparent throughput**. Measured
`Out` was 2,467/min on Jul 24 with h1 "working"; h1 was ~64% of rows, so real
enrichment was ~890/min. Since h1 came back doing genuine work, measured `Out`
is **~900/min** — the same number. The fleet's true capacity has always been
~900/min, and the 2,467–3,277/min figures were fiction.

Against CT inflow of ~3,900/min that means the queue grows ~3,000/min and fills
its 1M cap in roughly **4–5 hours**, after which `enqueue/1` returns
`:queue_full` and CT discoveries are silently dropped. The queue was already at
**78.5%** on Jul 24, so this is long-standing, not new — but it is now
unmasked, and it has a consequence:

**The master was OOM-killed at 2026-07-26 06:27:57** (`status=9/KILL`) and
auto-restarted. Queue growth → master memory → OOM is the same mechanism as the
earlier recrawl-balloon incident. It will recur while inflow exceeds capacity.

So the ~3.4M-domain recovery below **cannot be run as-is**: adding 3.4M items to
a queue that is already overflowing will just accelerate the OOM. Resolve
capacity first — more workers, less CT intake, or tighter pre-filtering.

## Order of operations

1. ~~**Fix h1's resolver**~~ — **done 2026-07-26**, verified end to end.
2. ~~**Unfence h1**~~ — **done**; it is back in the cluster and healthy.
3. **Fix the capacity/OOM problem** (see above). Until this is done, recovery
   will make things worse, not better.
4. **Deploy the code fixes** (resolver pinning + Inserter guard + `rdap_error`)
   to master and all workers. Note the deploy script builds from a fresh clone
   of `origin/master`, so these must be committed and pushed first.
5. **Then** run recovery phases 1–3.

## Fencing (already applied 2026-07-26)

Master drops h1's Erlang distribution traffic on `wg0`, persisted via
`netfilter-persistent`, so it survives reboot:

```bash
# INPUT rules 1-2, OUTPUT rules 1-2 on 45.63.7.58
iptables -L INPUT  -n --line-numbers | grep "FENCE h1"
iptables -L OUTPUT -n --line-numbers | grep "FENCE h1"
```

To unfence once h1 is healthy:

```bash
iptables -D INPUT  -i wg0 -s 10.0.0.7 -p tcp --dport 4369 -j DROP
iptables -D INPUT  -i wg0 -s 10.0.0.7 -p tcp --dport 9100:9155 -j DROP
iptables -D OUTPUT -o wg0 -d 10.0.0.7 -p tcp --sport 9100:9155 -j DROP
iptables -D OUTPUT -o wg0 -d 10.0.0.7 -p tcp --dport 9100:9155 -j DROP
netfilter-persistent save
```

Losing h1 costs nothing in real throughput — queue drain was 3,279/min with it
and 3,276/min without.
