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
    ║   /impressum      ──► emails  (legally mandated in DE/AT/FR — the    ║
    ║   /contact             highest-yield contact page in the EU)         ║
    ║   /about, /team   ──► emails  (the only page type that carries a     ║
    ║                        NAMED person rather than a role mailbox)      ║
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
| emails | `/impressum`, `/contact`, `/about` + homepage head/footer | makes a record actionable — see "Contact extraction" below |
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

**No duplicate rows, history only on change.** Records carry a content hash;
an unchanged business re-read next month writes nothing (the hash already
exists), a changed one becomes a new row beside the old (facts likewise,
keyed on their value). The compactor takes the newest fact per
(domain, fact, source) before applying source precedence.

**Schedule and files.** Wikidata and YC weekly (no files). SEC EDGAR,
Companies House and Sirene/INPI monthly — the cadence the registries
publish at — as full snapshots: `companyfacts.zip` + `submissions.zip`
(all XBRL filers), `BasicCompanyDataAsOneFile` (the whole UK register),
`StockUniteLegale` + the INPI ratios export (all French legal units /
accounts). Only the newest snapshot stays on disk
(`LS.Verification.prune_snapshots/1` after a successful run); Companies
House's monthly accounts zips (incremental, one per month) are staged into
`verification_ch_accounts` and deleted immediately.

Everything pulled is **persisted and dated**: the run log records URL,
snapshot, bytes, records and matches per tier; every parsed record — matched
or not — sits in `verified_source_records`, so nobody re-downloads a 2 GB
archive to answer "what does Companies House say about X", and a future
LLM-assisted linker can work over the unmatched rows offline.

## Pipeline 3 — HR boards (2026-08-26)

The Jobs enricher only saw a company's ATS board when it happened to
recrawl that company's careers page, so hiring data went stale between
recrawls. `LS.Verification.HRBoards` + `LS.Verification.WTTJ` make boards
standing assets (`hr_boards`, migration 014), refreshed on a daily
master-only cycle (`LS.Verification.BoardScheduler`):

0. **Discovery** — monthly, the Common Crawl CDX index is queried per
   platform (`jobs.lever.co/*`, `matchType=domain` for subdomain ATSs):
   every board URL the web-wide crawl has ever seen, with zero requests to
   the ATS itself. Discovered boards land domainless; `job_count` lives on
   the board row and `biz_career`/`businesses` writes begin the moment a
   domain is resolved (careers harvest, globally-unique name-key match, or
   WTTJ profile render). The domain is the join key: data waits on the
   board row until the domain exists in the product.
1. **Harvest** — board slugs are extracted from URLs already stored in
   `biz_career` (greenhouse, lever, ashby, workable, smartrecruiters,
   recruitee, workday, personio, breezy — ranked and chosen by how many of
   our domains reference each platform; iCIMS is a JS widget and
   teamtailor has no public JSON, both skipped). Attribution carries a *fan-out guard*: only domains that
   reference ≤ 2 slugs on a platform may claim a board — a careers page
   embeds its own board, a job aggregator references dozens, and without
   the guard a company's jobs get written under the aggregator's domain.
   Reserved path segments (`/j/` shortlinks, `/embed/`, `v1`…) are
   blocklisted; most workable URLs are shortlinks and yield no slug.
2. **Sync** — each stale board (> 7 days) is re-read from the platform's
   *public, unauthenticated* JSON API (the same endpoint their own widgets
   call), one at a time, 400 ms apart, ≤ 2,000 per cycle. Jobs land in
   `biz_career`; a `biz_enrichment_log` row (`render_engine='board_sync'`)
   lets the compactor fold `job_count` into `businesses` without any
   worker crawl. A 404/410 marks the board gone (`job_count = -2`) so we
   stop asking.
3. **WTTJ** — Welcome to the Jungle is a CloudFront-guarded JS SPA, so its
   FR company directory is walked through the camoufox sidecar with
   `settle_ms` (hydration wait), 4 s between pages, 40 pages per day. The
   listing is result-capped (~22 pages per query), so the sweep runs the
   unfiltered listing plus one query per letter. Slugs resolve to domains
   via `verification_domain_keys` (dehyphenated slug = FR name key, ~5%
   hit rate because legal names differ from brand names); unresolved slugs
   then get one profile render each (20/day) — the profile page carries
   the company website as its first non-social external link. A render
   that never hydrates (CDN-only shell) is retried; only a hydrated page
   without a website is marked unresolvable. The
   sidecar reaches h1 over WireGuard (`LS_BROWSER_BIND` lists the wg IP
   alongside loopback on that node only).

**Snapshot semantics (2026-08-26).** `businesses.positions_overview`
changed meaning: it now holds the functional hiring snapshot
(`Engineering:12|Sales:4 (18 open)`, shared taxonomy in
`LS.JobCategories`) instead of a seniority split. Both the worker About
enricher and the board sync write the same shape; `biz_career` rows stay
the raw per-posting evidence the snapshot is recomputed from.

Incident pinned in `test/ls/hr_boards_test.exs`: timestamps with
microseconds silently destroyed whole TabSeparated insert batches — the
same failure class as the three incidents in CLAUDE.md.

## Contact extraction — the scan window (2026-08-26)

`LS.HTTP.PageExtractor` reads a **bounded window** of every page, not the
whole document: capped `<head>` (32KB) + the first 100KB of `<body>` + the
**last** 100KB of `<body>`. The tail slice is the point — emails and imprint
links both live in the footer.

Before this it read only the first 100KB of `<body>` and dropped `<head>`
entirely. Measured against prod, that lost two distinct classes of address:

| loss | share of no-email domains | cause |
|------|--------------------------|-------|
| JSON-LD `schema.org/ContactPoint` | 6.6% | `<head>` discarded before scanning |
| footer addresses | 12.5% | 57% of homepages exceed 100KB |

Sampled by re-fetching 488 live business domains that the DB recorded as
`http_emails = ''`. 19.1% of them had a findable address on the homepage the
whole time — roughly 1.08M domains fleet-wide.

**Why 100KB and not more.** Yield and peak process heap, measured on 393 real
homepages (mean 186KB, max 2.4MB), one isolated process per page:

| window | yield vs uncapped | median heap | p95 | max |
|--------|------------------:|------------:|----:|----:|
| old (100k prefix, no head) | 74.8% | 2,628 KB | 10,578 KB | 11,213 KB |
| head + 100k + 100k | 96.1% | 2,528 KB | 11,055 KB | 15,091 KB |
| head + 150k + 150k | 97.6% | 2,192 KB | 12,897 KB | 20,755 KB |

150k buys 4 more domains out of 393 for +85% peak heap and −11% throughput.
100k costs +35% peak and −2%. At HTTP concurrency 100 that is ~1.5GB worst
case rather than ~2.1GB, which is what the 1-core nodes can carry. Median
heap *improves*, because cleaning now runs over a bounded window instead of
over documents that reach 2.4MB.

**Two traps, both pinned by tests.** Slicing at a byte offset can cut a
multi-byte UTF-8 codepoint, and the resulting invalid binary makes
`String.downcase/1` raise — which every caller rescues to `nil`, so the page
silently reports nothing. And a slice landing inside `<style>` leaves an
opening tag whose regex then matches to the next closer far away, deleting
every link between: observed on a site with 246KB of inline CSS, which
collapsed a 118KB window to 16KB.

### Page kinds

`page_kind/1` gained `:legal` and `:about`. Imprints are matched by **stem on
the last path segment** as well as by exact path, because Shopify nests them
(`/pages/impressum`), localised sites prefix them (`/de/impressum`) and
hand-built sites suffix them (`/impressum-rechtliche-hinweise.html`). That
took German imprint detection from ~0% to 95.1% on domains known to have one.

`/legal`, `/terms` and `/privacy` are deliberately **excluded** — they name
policy documents that carry a law firm's or parent company's address on most
sites, and matching them attributes the wrong company's mailbox to the
business.

`page_priority/1` now orders by how likely the page is to carry an address
(legal → contact → about → pricing → career → …) and `cap_per_kind/1` keeps at
most two paths per kind, because `@max_pages` truncates: a shop with a dozen
product links used to push its `/impressum` out of `http_pages` entirely.

### What this does NOT do

Extraction does not check that an address belongs to the site it was found
on. Imprint pages carry third-party addresses — the agency that built the
site, the host, statutory arbitration boards such as
`schlichtungsstelle@s-d-r.org`. On the German sample that is the difference
between a 40.6% recovery rate and an honest 28.1% on-domain one. **A consumer
that needs "this business's own email" must filter to the domain itself.**
`biz_contact.source_page` now records which kind of page each address came
from, so that judgement is possible downstream; it used to be hardcoded
`"contact"` for every row.

## Secondary-page fetching — the funnel (2026-08-26)

Measured on 300 domains through the real `LS.HTTP.Client` (production jitter
and politeness limiter), because until this release **nothing recorded
per-page outcomes**: `Enrichment.Agent.fetch_page/3` collapsed every failure
into `%{html: nil, source: "failed"}`.

| Step | Rate |
|---|---:|
| DNS resolved | 99.3% |
| Homepage fetch OK | 95.7% |
| Secondary pages OK | 76.2% |

By position: 78.3% / 75.3% / 73.8% for pages 2/3/4 — about 1.5 points lost per
extra page, a slope rather than a cliff — and **zero `:rate_limited` at any
depth**. The politeness limiter is not the constraint; going deeper is safe.

### The cause: a redirect follower that kept the old path

`LS.HTTP.Client.resolve_redirect/3` now resolves the `Location` header against
the URL just requested and carries the resulting **host and path**. It used to
switch host but re-send the ORIGINAL path, and ignore relative `Location`
headers entirely. The commonest redirect on the web is a trailing slash on the
same host (`/contact` → `/contact/`), so we re-requested `/contact`, got the
same 301, and burned every hop:

| Failure | Share of secondary-page failures |
|---|---:|
| `too_many_redirects` | 49.5% |
| 404 (stale recorded path) | 24.2% |
| raw 301/307/308 returned as content | 18.7% |
| timeouts | 4.4% |
| 4xx/5xx | 2.7% |

**~68% of failures were that one line.** The homepage was largely spared
because redirecting `/` to `/` on a new host happens to be correct — which is
why this hid for so long behind a healthy-looking 95.7%.

### `biz_page_fetch` — so the next one is a query

One row per attempted fetch, homepage included: `domain`, `page_kind`, `path`,
`outcome` (`ok` / `thin` / `http_error` / `rate_limited` / `redirect_loop` /
`timeout` / `error`), `status`, `elapsed_ms`. 90-day TTL. The funnel above is
now a `GROUP BY page_kind, outcome` instead of a hand-run probe.

### `/login` is no longer fetched by enrichment

It was in `pages_to_visit/2`'s default for months and `html_of(visited, :login)`
is called **nowhere** — one wasted request per enriched domain. Login-page tech
detection is real but happens in DISCOVERY
(`LS.Pipeline.enhance_with_secondary_pages/3`, which fetches `/login` and
`/pricing` and unions the result into `http_tech`). Dropping it here pays for
most of the cost of adding `:legal` and `:about`.

Tech detection coverage, for the record: **97.1%** of live non-junk domains
carry some `http_tech` and **54.9%** carry an identifiable backend or CMS
(WordPress 9.24M, PHP 4.80M, Apache 4.92M, Nginx 4.56M, WooCommerce 2.80M).
Session-cookie signatures are the most reliable backend tell and now also cover
Symfony, CakePHP, Flask, FastAPI, Phoenix, PrestaShop, Magento, TYPO3, Odoo and
Strapi.

### `biz_contact.on_domain`

Imprint pages are legally required to name a contact and routinely name someone
else's — the site's agency, its host, or a German statutory arbitration board
(`schlichtungsstelle@s-d-r.org` is boilerplate). On German business domains,
40.6% yield an address from a second page but only **28.1%** yield one on the
business's own domain.

The flag marks them; it does **not** filter. An off-domain address is real
signal — the agency relationship is itself sellable, and for a tiny business a
freemail address is often the only reachable human. Any buyer-facing surface
that promises "this business's email" must filter `on_domain = 1`.
