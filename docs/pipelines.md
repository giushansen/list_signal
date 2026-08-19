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

## Pipeline 3 — Verification (2026-08-18)

The first two pipelines *observe* a business; the third *proves* parts of
it from sources that carry legal weight or curated data:

| source | facts | how it links to our domain |
|---|---|---|
| Wikidata (SPARQL) | revenue, employees, industry, inception, HQ | official website (P856) → exact domain |
| SEC EDGAR bulk (`companyfacts.zip` + `submissions.zip`) | latest fiscal-year revenue, filer name/SIC | `website` in submissions; name + US fallback |
| Companies House bulk (register snapshot + monthly iXBRL accounts) | turnover, average employees, SIC, incorporation | name + GB (no website in the register) |
| Sirene stock + INPI ratios (data.gouv.fr) | employee band, chiffre d'affaires | name + FR |
| YC directory (public Algolia index) | team size, batch, one-liner | website → exact domain |

Same discipline as pipelines 1 and 2, plus three rules of its own:

1. **It runs on one node**, the master, as one polite client with our
   User-Agent (`ListSignal/1.0 <contact>`), ≥ 1 s between requests per host.
   These are official endpoints: spreading them over the fleet would look
   like ban evasion and buys nothing (bulk files are single downloads).
2. **It never guesses a link.** Website URL → registrable domain → exact row
   in `domains_current`; or normalised legal name + country → exactly one
   label in `businesses` AND exactly one record with that key in the source.
   Ambiguity = skip. `match_method` is stored on every fact.
3. **It writes only its own tables and NEW columns.** `verified_facts`,
   `verified_source_records`, `verification_runs`, and the compactor fills
   `businesses.verified_revenue/_source`, `verified_employees/_source`,
   `mission_summary`. `estimated_*` is untouched; the data-contract suite
   asserts a verified value never coincides with a blanked estimate, that
   every linked domain exists in `domains_current`, and that verified
   brackets are the estimator's vocabulary (so filters keep working).

Everything pulled is **persisted and dated**: the run log records URL,
snapshot, bytes, records and matches per tier; every parsed record — matched
or not — sits in `verified_source_records`, so nobody re-downloads a 2 GB
archive to answer "what does Companies House say about X", and a future
LLM-assisted linker can work over the unmatched rows offline.
