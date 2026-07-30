# The two pipelines

ListSignal runs **two** crawling pipelines with opposite goals. They share
every resolver, cache and rate limiter, but write to different tables — and
that separation is the whole point.

```
                          CT LOGS (8 feeds, ~4000 domains/min)
                                       │
    ╔══════════════════════════════════▼═══════════════════════════════════╗
    ║  PIPELINE 1 — DISCOVERY                    breadth · fast · cheap    ║
    ║  10 VPS workers      LS_LANES=discovery                              ║
    ║                                                                      ║
    ║   DNS ──► [ HTTP peek ∥ BGP ∥ RDAP ] ──► classify ──► merge          ║
    ║   ~40ms    5s timeout, homepage only                                 ║
    ╚══════════════════════════════════╤═══════════════════════════════════╝
                                       │ one row per crawl
                                       ▼
                            ┌────────────────────┐
                            │  domains_history   │  append log, TTL 365d
                            │  126M rows         │  ← cybersecurity dataset
                            └─────────┬──────────┘
                                      │ MV
                                      ▼
                            ┌────────────────────┐
                            │  domains_current   │  newest row per domain
                            │  93M rows          │
                            └─────────┬──────────┘
                                      │ "which are real businesses?"
                                      ▼
                            ┌────────────────────┐
                            │  EnrichmentQueue   │  refilled from ClickHouse
                            │  (master)          │  every 5 min, depth 5000
                            └─────────┬──────────┘
                                      │
    ╔═════════════════════════════════▼════════════════════════════════════╗
    ║  PIPELINE 2 — ENRICHMENT                   depth · slow · valuable   ║
    ║  big nodes / home NUC     LS_LANES=enrichment                        ║
    ║                                                                      ║
    ║   /products.json  ──► catalog stats      (JSON, no browser)          ║
    ║   ATS job API     ──► open roles          (JSON, no browser)         ║
    ║   /contact        ──► emails                                         ║
    ║   /pricing        ──► plan prices                                    ║
    ║   homepage HTML   ──► SEO score + Core Web Vitals                    ║
    ║                                                                      ║
    ║   camoufox (max 3 concurrent) ONLY when HTTP is refused or the        ║
    ║   page needs JavaScript                                              ║
    ╚═════════════════════════════════╤════════════════════════════════════╝
                                      │
              ┌───────────────┬───────┴───────┬────────────────┐
              ▼               ▼               ▼                ▼
        biz_contact      biz_career      biz_pricing      biz_summary
        (1:many)         (1:many)        (1:many)         (1:1 signals)
              │               │               │                │
              └───────────────┴───────┬───────┴────────────────┘
                                      ▼
                            ┌────────────────────┐
                            │     COMPACTOR      │  every 5 min,
                            │  (master)          │  changed domains only
                            └─────────┬──────────┘
                                      ▼
                            ┌────────────────────┐
                            │    businesses      │  ← THE PRODUCT
                            │  6.4M rows, flat   │    app · API · CSV
                            └────────────────────┘
```

## Why pipeline 2 cannot corrupt pipeline 1

Pipeline 2 writes **only** `biz_*` tables. It has no code path that touches
`domains_history` or `domains_current`. Before this design, both pipelines
wrote the same wide row and the newest row won — so a crawl that skipped a
stage (cached RDAP, blocked HTTP) blanked data an earlier crawl had fetched.
That spoiled ~7.8M domains.

The compactor then assembles `businesses` with **last non-empty per signal
unit**, not newest-row-wins:

```sql
argMaxIf(http_title, enriched_at, http_status BETWEEN 200 AND 399)
--                                ^ only rows where the fetch SUCCEEDED
```

A failed crawl therefore cannot erase a good value, and a camoufox render that
succeeds automatically wins over an HTTP attempt that was blocked — no
priority logic to maintain.

WAF-blocked businesses are enrichment **candidates on purpose**: discovery's
plain HTTP never gets a 2xx from them (`crawlable = 0`), but camoufox usually
does, so the refill query admits them alongside crawlable ones. When a browser
render succeeds after a block was recorded, the compactor clears
`last_http_blocked` — the flag means "outstanding: nothing has reached this
site since the block", and a successful render is exactly such a success.

## Lanes

A worker runs whichever lanes `LS_LANES` names:

| Setting | Node | Runs |
|---|---|---|
| `discovery` (default) | the 10 small VPS | `LS.Cluster.WorkerAgent` |
| `discovery,enrichment` | a big node | both |
| `enrichment` | home NUC (residential IP + camoufox) | `LS.Enrichment.Agent` |

Both lanes go through `LS.HTTP.Client`, so the per-IP rate limiter and the
politeness caches apply identically. **This is not optional**: our source IPs
are the most fragile asset in the business, and pipeline 2 visits several
pages per domain.

## What pipeline 2 collects, and why it sells

| Data | Source | Why buyers pay |
|---|---|---|
| `perf_lcp_ms` on `render_engine="http"` rows | measured fetch time × 1.6 | ESTIMATE — real LCP/CLS only exist where camoufox rendered (blocked sites + HTTP-failures) |
| `product_count`, `price_avg`, `new_products_30d` | Shopify `/products.json` | store size + price tier + is it actually growing |
| `last_product_at` | same | best dead-store signal there is |
| `job_count` + departments | Greenhouse/Lever/Ashby JSON | the best public proxy for growth and funding |
| `ats_platform` | job board URL | a tech signal competitors don't sell |
| emails | `/contact` | makes a record actionable |
| plan prices | `/pricing` | SaaS positioning |
| `seo_score` + issues | homepage HTML | the pitch for agencies |
| `perf_lcp_ms`, `cls`, `ttfb` | camoufox | real Core Web Vitals |

Both `/products.json` and the ATS boards are **public JSON APIs** — no browser
needed, so the expensive part of pipeline 2 is small.
