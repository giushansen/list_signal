# Crawl capacity and IP safety — measured envelope

**Read this before raising any node's outbound request rate.** The numbers
here are measured on production traffic, not guessed. Update them when you
re-measure; never scale past the envelope on a hunch.

## The measured safe operating point (2026-08-25, 24h, ~1.68M fetches)

Per-node HTTP fetch rates and refusal rates, all 11 fetching nodes:

| Node | Source IP type | Fetches/min | 429 rate | Hard blocks |
|------|---------------|------------:|---------:|------------:|
| ny1, ny2, chi1, chi2, par1 | datacenter | 128–161 | 0.69–0.99% | 0 |
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
