# Crawl capacity and IP safety

**Read this before changing anything that sends a request.** Two rules,
in this order, decided by the owner on 2026-11-03. Everything else in this
file is the measurement behind them.

## Rule 1: politeness per target comes first

Every target, whether one site, one address or one provider's shared
edge, sees a rate under what it tolerates, with margin. The setpoint
follows the slowest tolerance we know of, not our own convenience, and a
refusal (429, 430, 503, Retry-After) slows us further on that target
before anything else happens. The per-target spacing and the back-off
are never removed or loosened to gain throughput; if a target is too slow
for the product, the answer is more source addresses or fewer requests
to it, never a faster clock.

What that means in code today:

| Target | Setpoint per node | Where |
|---|---|---|
| any host address | one request a second (`check_and_update(ip, 1000)`) | `LS.HTTP.IPRateLimiter`, `LS.HTTP.Client` |
| Shopify edge (23.227.38.0/24, all stores) | one key, two seconds between requests | `IPRateLimiter.@edge_spacing_ms` |
| Wix, Squarespace edges | one key each, one second | `IPRateLimiter.@shared_edges` |
| Cloudflare addresses | per address, one second (Cloudflare limits per site, not per client) | same |
| after a 429, 430 or 503 | the key pauses 5 s, then 10, 20... up to 5 min within 10 min, or Retry-After if longer | `IPRateLimiter.penalize/2` |
| several callers on one key at once | booked one after the other at the key's spacing (`book/2`); a place more than 10 s out is a refusal that returns the node slot | `IPRateLimiter.book/2`, `NodeBudget.release/2` |
| any one site per visit | robots.txt, the homepage, at most one secondary page, redirect hops | `LS.Cluster.WorkerAgent`, `LS.Pipeline.secondary_plan/2` |
| robots.txt | obeyed, cached 24 h (RFC 9309), the opt-out /bot promises | `LS.HTTP.Robots` |
| identity | one declared user agent, `ListSignalBot/1.0 (+https://listsignal.com/bot)`, never rotated | `LS.HTTP.Client` |

What the platforms tolerate, as far as anyone publishes it (researched
2026-11-03, sources in the engineering log entry of that day):

- No CDN or host publishes a per-client-IP rate for ordinary page
  traffic. Rate rules are per site and owner-set: Cloudflare one rule per
  10 s window on the free plan, AWS WAF at least 10 requests per 5 min
  window, Akamai "never above 20 a second" with typical policies at 3 a
  second average and 5 burst, Google Cloud Armor's default policy 500 a
  minute. We make three requests per site per visit, so no per-site rule
  can trip on us.
- What trips is classification, not rate: an unknown non-browser client
  from a datacenter address is challenged or refused on its first request
  by Cloudflare Bot Fight Mode, AWS Bot Control, Imperva, Akamai Bot
  Manager and Vercel's bot protection. That is the 403 and the Cloudflare
  challenge we see on 1.5 to 3% of fetches, flat across nodes, and it
  does not move with rate.
- Shopify is the one host that answers rate with 429 at our volumes:
  5.05% of Shopify fetches on 2026-11-02/03 at one request a second per
  node, 92.4% of the fleet's 429s, 15.9% on sg2. Shopify publishes no
  number, tightened unsigned-bot limits on 2026-05-30, and crawler vendors
  run it at 500 ms between request starts with back-off. Two seconds per
  node plus back-off is the setpoint until the edge reads under 1%.
- Every platform that honours a crawler identity (Cloudflare Verified
  Bots, AWS Bot Control, Vercel, Shopify) now does so through Web Bot Auth
  (an Ed25519 key directory at /.well-known and signed requests). That is
  the next step for the 403 band, not a faster clock.

How we read the other side's answer:

| Answer | Meaning | What the code does |
|---|---|---|
| 429 | slow down (per site, or Shopify per client) | pause the key; the candidate goes back to the queue tail once, no row |
| 430 | Shopify security rejection (client looks malicious) | pause the key; recorded |
| 403 | WAF policy or bot classification, not rate | recorded, excluded from plain refresh, browser lane |
| 503 with challenge body | Cloudflare/WAF refusing a bot | pause the key; browser lane |
| `cf-mitigated: challenge`, "Just a moment" title | Cloudflare challenge | not observed; browser lane |
| 520 to 526, 530 | origin down, unreachable or misconfigured, not rate | recorded as down |
| 404 or 5xx on a Cloudflare address at first contact | a zone with no origin yet | recorded, not refreshed until re-sighted |
| 304 | unchanged since our validators | kept as the last full read, no page, no secondary |

## Rule 2: never idle inside rule 1

Within rule 1, every node runs at what its source address allows, all
the time. A reserved slot nobody uses is a slot wasted, and in Elixir a
process waiting on nothing is a bug. Concretely: the per-node ceiling
(`LS.HTTP.NodeBudget`, `LS_FETCH_PER_MIN`) is spaced evenly and shared
by both lanes; the depth lane's reserve is lent to discovery while the
depth line is idle; every request from our address, redirect hops
included, takes a slot so the ceiling is real; the batch cap and
deadlines are sized so the line is booked a minute or two ahead and the
stage ends when the line, not a timer, says so. Idle is measured, not
assumed: `NodeBudget.backlog_ms/1` reads 0 on an idle line, and the
per-node request rate is `LS.HTTP.PerformanceTracker.stats().rate`.

Measured 2026-11-03 before this rule was applied: the discovery line on
ny1 was booked 63 to 127 s ahead on every sample (saturated), the
enrichment line read 0 on every sample of ny1, chi1, par1 and dal1
(idle), the depth lane fetched 107 pages a minute across the whole fleet
against 270 a minute reserved on the nine duals, and ny1 sent 157
requests a minute against a 120 budget because redirect hops took no
slot.

Measured 2026-11-03 two hours into the ny1 trial (everything counted,
ceiling 150): 127 requests a minute on average, 141 in a window with both
lines booked ahead, 28% of them redirect hops; the depth line booked 6 to
9 s ahead on every sample (its reserve fully used); the discovery line
drained to zero between batch phases about one minute in ten; 5.7% of
rows were our own refusals from Shopify candidates racing for the
edge's spacing after taking a node slot. The old code on ny2 and chi1
sent 155 to 157 a minute against a 120 ceiling that counted no hop. A
counted ceiling of 155 is therefore no more than the fleet's addresses
have been sending for months, and the setpoint on the trial node.

Two hours at that setpoint with three staggered batches (12:03 to 14:02
UTC): 150 requests a minute counted, 33.0 rows a minute against 30.0 to
32.6 on the old code, 0 429s, the BEAM at 1.1 GB on a 4 GB node. That is
the dual profile to roll out: `LS_FETCH_PER_MIN=155`,
`LS_WORKER_BATCHES=3`, every request counted.

---

## The measured safe operating point (2026-08-25, 24h, ~1.68M fetches)

Per-node HTTP fetch rates and refusal rates, all 11 fetching nodes:

| Node | Source IP type | Fetches/min | 429 rate | Hard blocks |
|------|---------------|------------:|---------:|------------:|
| ny1, ny2, chi1, chi2, par1 | datacenter | 128–161 | 0.69–0.99% | 0 |

(Rows for sg1, syd1, chi2, dal2 and par2 are kept as measurements; those nodes were destroyed on 2026-10-22 when the fleet went from 13 workers to 6 plus h1, see docs/engineering-log.md.)
| sg1, syd1 | datacenter (1-core) | 136 | 0.41–0.50% | 0 |
| dal1, dal2 | datacenter | 20–24 | 0.58–0.75% | 0 |
| **h1 (NUC)** | **residential** | 132 | **1.00%** | 0 |

Interpretation:

* **~130–160 fetches/min per source IP is proven safe**: sub-1% 429s (almost
  all per-site rate limits, not IP reputation), zero hard blocks, zero
  Cloudflare/AWS refusals at the connection level, IPs clean after months.
* The 403 rate (~5%) is flat across ALL nodes including brand-new ones, so it
  is target WAF *policy*, not our reputation — it does not rise with rate.
* **h1 already sits at the top of the 429 band** (1.00%, the highest in the
  fleet) at the same per-minute rate as everyone else — its higher HTTP
  concurrency (400) makes its traffic burstier. It has NO safe headroom for
  more outbound fetch rate, and its residential IP is irreplaceable.

## The rule that follows

> **Capacity comes from MORE source IPs, never from more rate per IP.**

A new $10.40 1-core node arrives with a fresh IP already inside the proven
envelope (sg1/syd1 do ~520–540 domains/min each). Pushing an existing node to
2–3× the measured band moves it into territory where we have NO data — and
the first data point past the edge is a blacklisted IP, which is an
existential risk (see CLAUDE.md, "Crawling — non-negotiable").

Deliberate ramp-to-refusal testing was considered and rejected for the NUC:
its residential IP cannot be replaced for $10.40. If a true edge-finding
probe is ever wanted, run it from a disposable VPS IP, one variable at a
time, and record the result HERE.

## What the NUC's 16 cores ARE for

Not more fetches. The residential IP's value is *qualitative*: WAF-walled
sites that refuse datacenter IPs. h1 gets browser-tier (camoufox, max 3
concurrent) and blocked-domain affinity via its `:residential` node class
(`LS.Cluster.EnrichmentQueue.browser_share/2` steers the browser backlog to
it). Spare cores are for parsing/ML — CPU-bound work that adds zero outbound
requests. The per-IP politeness limiter (`LS.HTTP.IPRateLimiter`, 3s per
target IP per machine) stays, always.

## Node classes (so nobody re-invents the flag)

* `LS_LANES` (env, per node): `discovery`, `enrichment`, or both — which
  pipelines the node pulls work for.
* Node class `:residential` vs `:datacenter` (from the worker's reported
  class, see `EnrichmentQueue.dequeue_lane`): which *kind* of enrichment work
  it is steered — residential gets the browser/WAF backlog first.
* `fleet.conf` role column is documentation for humans + deploy tooling; the
  runtime truth is `LS_LANES` in `/home/ls/.env.local` on each node.

## Change-aware revisits (2026-09-09)

The envelope above is per source IP; the other side of capacity is how many
fetches the crawl needs. Measured 2026-09-09: 73.9% of a week's crawls are
revisits and 88.9% of those return an unchanged site. `LS.Cluster.CrawlDedup`'s
stable ring skips a revisit for 28-35 days once a domain has come back
unchanged (top-100K domains excepted), which at steady state removes about
half of all fetches. Read `LS.Cluster.WorkQueue.stats().total_deduped_stable`
against `total_enqueued` before deciding node counts; the fleet's fetch
budget should follow the fetches actually needed, not the number of domains
discovered.

## The per-IP ceiling, and why 120 (2026-10-03)

The budget (`LS.HTTP.NodeBudget`, `LS_FETCH_PER_MIN`) was 140 and the fleet
averaged about 70 fetches a minute per node anyway: a worker ran one batch
at a time, and the fetch budget sat idle during the DNS stage (15 s), the
merge and the ML stage (18-58 s), a third of every cycle. Two staggered
batches per 4 GB node fill that gap (`LS_WORKER_BATCHES`); the budget is
node-wide, so the ceiling cannot be exceeded by running two.

The ceiling itself is set to 120 a minute, two a second. The measured safe
envelope is 130-160 (sub-1% 429s, zero blocks); 120 keeps a margin under
it. Two facts about how the other side judges us: no CDN or firewall
documents a global per-client rate, their rate rules are per site and we
make one request per site per visit, so they never trip; what does trip
is reputation, which is keyed on breadth (one address touching thousands
of unrelated sites) and on identity (user agent, reverse DNS, honeypot
links). Every abuse report so far came from a honeypot or a listed site,
not from rate. "At most one request per second to any host", the promise
on /bot and to Vultr, is a per-target statement and holds at any node rate.

**The ceiling is shared by two lanes, with a reserve.** On a dual node the
depth lane (pipeline 2) fetches through the same client as discovery. The
hour the budget became airtight, two discovery batches kept the line full
and every depth fetch queued behind a minute of discovery slots; a depth
domain visits up to four pages, so it blew its 120 s task timeout. ny1
dropped 108 of 120 depth domains in an hour, chi1 101 of 112, the fleet
wrote 1,200 depth rows an hour against 5,300 the day before. The
enrichment lane now holds `LS_ENRICH_FETCH_PER_MIN` (default 30) of the
ceiling on its own line and discovery gets the rest (90 on a dual node,
45 per batch). The shares add up to the ceiling: the source IP sends no
more than before. An enrichment-only node (h1) keeps the whole ceiling.

**2026-11-04, the edge lane.** With the booking limiter on every node, the
30-minute tier A tick (4,467 at priority 0, Shopify-heavy) started 60 to 190
Shopify stores per node at once; the 2 s edge line booked 16 inside the 30 s
horizon and refused the rest, and a store refused twice in one wave was
recorded as rate_limited and shelved for its cadence: 350 to 835 stores a
wave, about 45% of the wave's Shopify stores, while the line sat idle between
waves. Rule 2 inside rule 1 now means: targets behind a shared edge run in a
lane four wide per node, shared by the batches (one per batch on a dual, 8 s
ahead at most on the 2 s line), and the tier A allowance goes out in six
slices of 750 inside the tick.

**2026-11-04, one hour later: the lane was first four wide per batch.** Three
batches kept the Shopify line 23 to 24 s deep between waves on ny1 and sg2:
inside the 30 s discovery horizon, so the lane was never refused, but over
the 5 s a redirect hop accepted and the 10 s depth horizon. Shopify rows
ending as a bare 301 (hop not followed) went from 3 to 6% to 17 to 25% the
moment the booking limiter went out on 2026-11-03 15:43 UTC, about 1,000
stores an hour. A hop now books its place within its lane's horizon like any
first contact, same host or not, and the width is per node. The rule of
thumb that falls out: the bookings all callers on one node can hold on a
shared line must stay under the shortest horizon any caller has (10 s for
the depth lane), or the shortest-horizon caller is the one always refused.

**2026-11-04, four hours later: the lane is off by default.** It kept every
batch's HTTP stage running to its deadline, so the three batches no longer
took turns on the node's slots and each stage cut a third to two thirds of
its candidates after spending slots on them: sg2 34 rows a minute to 24,
fleet 2xx rows about 180 a minute to 56 to 130, master queue 40K to 74K in
three hours. The capacity fact underneath: a Shopify store costs about four
requests on the 2 s line (robots.txt, homepage, hop, contact page), so a
node serves about 7 stores a minute and seven duals about 3,400 an hour,
while the tier A tick asks for more than that. Refusing at the horizon sheds
the surplus at once; the lane sheds it late and takes plain work with it.
`LS_EDGE_LANE=on` turns the lane on for one node to trial a change.

**2026-11-04, 07:00 UTC: the owner chose the lane, on everywhere.** The fleet
profile sets `LS_EDGE_LANE=on` on every worker (devops 7c9bf3e); the app
default stays off so a fresh node without a profile is the conservative
one. The trade accepted: fewer rows a minute per node, a fuller line, no
bursts of own refusals. The capacity fact above still stands, so the next
lever is the cost of a Shopify store on the line (four requests today) or
more source addresses, never more rate per address.

**2026-11-04, 17:30 UTC: a batch holds at most eight shared-edge stores.**
The share alone did not bring the duals back: the queue handed stores out
in runs (up to 413 in a row, 51% of an 18.6K priority queue), and a batch
on a run fetched 13 of 82 in its stage. The master's queue now walks over
shared-edge names past eight a batch and leaves them in place for later
batches. The line stays full (three batches of eight at six requests
each are about 29 of the 30 requests a minute a node) and no batch is
choked. Capacity is unchanged: about 5 stores a minute a node, 2,100 an
hour on seven duals, the 120 a slice tier A share plus what certificates
bring. The lever is still the cost of a store or more addresses.

**2026-11-04, 10:30 UTC: the refresh admits Shopify stores at the edge's
capacity.** The lane on and the tier A tick sliced, the batches choked on
Shopify stores anyway: 42% of the due tier A list is Shopify, those items
are dequeued first, and the cut stores returned to the head of the queue.
The scheduler now takes at most 120 Shopify stores a slice (24 a minute
on seven duals, about 3.4 a node, 14 to 27 of the 30 edge requests a
minute a node) and fills the rest of the 750 from the plain list. The
number is the fleet's edge capacity with room for the stores certificates
bring; it moves with the number of source addresses, not with demand.
