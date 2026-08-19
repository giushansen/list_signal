# Data quality — golden set, is_junk, calibration

The product *is* the data: a wrong `business_model` or a parked domain in a
CSV export is a refund waiting to happen. This doc describes the measurement
loop that keeps accuracy improvements honest. Started 2026-08-07.

## The golden set

A stratified sample of prod `businesses` rows, hand-labeled by the owner, in
`analysis/golden_set/golden_set_v<N>_<YYYY-MM-DD>.csv` (labeling instructions
in `analysis/golden_set/README.md`).

- **v1 (2026-08-07)** — 151 domains, sampling seed `gset7`. Strata: 5
  high-confidence + 5 low-confidence per business model (11 classes), 20
  unclassified-but-Tranco-ranked, 6 per revenue bracket. Alive sites only
  (`last_http_status = 200`, `dns_alive = 1`) so every row is checkable by
  clicking it.

  **Labeled 2026-08-12.** Provenance is mixed and every row records it: rows
  1–35 were labeled by the owner; the remaining 116 were labeled by Claude
  (Fable 5) from a fresh fetch of every homepage plus web searches for the
  large-company revenue brackets — those notes all start with `AI:`. Nine
  owner rows carry an appended `AI-check:` flag where the independent AI read
  disagreed (owner labels were NOT changed; adjudicate before treating those
  rows as settled). Ten AI rows were labeled behind a WAF block or an empty
  JS shell, i.e. from model knowledge of the company, not page content —
  their notes say so. Headline numbers: junk rate 23.8%; model accuracy
  high-band 53.7% vs low-band 42.2% (confidence is barely calibrated);
  per-class precision from 0% (Marketplace) to 90% (Education); revenue
  exact-bracket 65.8% overall but only 12–18% for predictions ≥$10M.
  Because 77% of labels are LLM-authored, treat v1 as *LLM-assisted* ground
  truth: fine for finding broken classes and calibration, weaker as the
  final word on any single row. The distillation tier planned below must not
  be evaluated against AI-labeled rows without owner spot-checks — that
  would be an LLM grading itself.

Label it with `analysis/golden_set/label.html` — a self-contained page (no
server, no network) that walks the set one domain at a time, keeps progress in
`localStorage` and exports a CSV with the same columns. `Load other CSV` makes
it work for every future version.

Score a (partially) labeled set with:

    mix ls.golden_eval                # newest set under analysis/golden_set/
    mix ls.golden_eval path/to.csv

(`LS.GoldenSet` does the parsing/scoring; the mix task is a thin wrapper.)
It reports junk rate, per-class model/industry precision, accuracy by
confidence band (is the "confident" tier actually more accurate than the
near-cutoff tier?), revenue-bracket accuracy, and how many real businesses
the unclassified bucket hides (a recall proxy).

**Versioning rules — the whole point of the exercise:**

1. Never tune the classifier and the golden set in the same change. The set
   is frozen while it is the measuring stick.
2. Grow v(N+1) from v(N)'s disagreements plus a fresh stratified sample;
   bump N and the date in the filename. Old versions stay in git.
3. A classifier change ships with before/after `ls.golden_eval` numbers in
   the commit message or PR.

## Classifier v2 (2026-08-12) — measured against frozen v1

Shipped from golden v1's findings, every change measured with
`mix ls.golden_reclassify [--ml] GOLDEN.csv PAGES_DIR` (re-runs the current
classifier over the set's cached homepage HTML; `--ml` reproduces the full
heuristic+ML shipping path):

- **LocalBusiness** is the 12th business model — physical businesses (trades,
  clinics, salons, restaurants, venues, brokerages) whose site is a presence,
  not the product. Previously they were smeared across Consulting/Tool/
  Ecommerce; v1 found 10 of them. Consulting now means advisory only.
- **Keyword traps closed**: Newsletter/Marketplace/Tool/Community/Directory
  (0–33% precision in v1) can no longer be claimed from body text or by the
  ML tier — they need title/H1/meta or platform-tech evidence and a higher
  per-class confidence bar (`@class_min_confidence`).
- **Confidence repaired**: a single weak signal used to yield ratio 1.0 and
  ship at 0.6+ (v1's `Newsletter@1.0` on a signup widget); an evidence prior
  now dampens lone signals. Industry is gated on its own evidence
  (≥ 0.45) instead of riding the model's confidence. **Meaning change:** on
  industry-only rows, `classification_confidence` now describes the industry
  label. ML tier: floor 0.5, stored confidence capped at 0.85 (measured sweep;
  0.45 diluted Agency to 44%, 0.58 cut coverage to 39% for no precision).
- **Result on v1 (144 rows with cached HTML)**: precision of shipped labels
  46.1% → 56.7%; coverage 86% → 46% — deliberate: a wrong label is a refund,
  an unclassified row is future work for the LLM tier. Junk recall 19/28
  (partly in-sample — several detector strings came from v1's own junk rows;
  v2 is the out-of-sample check).

## is_junk

`is_junk` (LowCardinality(String), since `clickhouse/migrations/004_is_junk.sql`)
lives on `domains_history`, `domains_current` and `businesses`:

- `""` — no junk detected (**not** "verified real"; an unfetched page has
  nothing to judge)
- `"parked"` — domain-for-sale / registrar parking page (now multi-language,
  incl. the Dovendi/1st-Domains/short-domain templates from golden v1)
- `"placeholder"` — default Shopify/WordPress storefront, hosting shell,
  homepage-404, "coming soon"
- `"empty"` — successful 2xx/3xx whose page has no title/H1/text/links (v1
  found HTTP 200 with a 0-byte body). Never set on failed fetches or
  JS-rendered shells (`is_js_site`) — but note a bot-wall serving an empty
  200 to the HTTP tier can still land here (v1: two bank sites); route
  `"empty"` to the browser lane rather than excluding it from exports.
- `"scam"` — narrow fraud templates (crypto "withdrawal resolution" recovery
  scams). Deliberately conservative: a false "scam" on a real business is
  worse than a missed one.

Detection is `LS.HTTP.BusinessClassifier.junk_reason/1` — the same checks that
already gated `classify/1`, now recorded instead of silently swallowing the
row. In `businesses` the flag follows the *newest successful fetch*
(`argMaxIf(..., http_status BETWEEN 200 AND 399)`): a parked domain that comes
back to life clears it, a real site that dies into a parking page gains it —
unlike `is_malware`/`is_phishing`, which are sticky by design.

The explorer supports `exclude_junk=true` (opt-in). Flip it to
exclude-by-default only after the golden set confirms the detector's
precision — a false "parked" on a real business silently hides a sellable row,
which is worse than showing a parked one.

## Golden set v2 (2026-08-12) — the out-of-sample check

180 fresh domains, seed `gset8`, same strata as v1 (v1 domains excluded),
sampled from prod BEFORE classifier v2 deployed so `predicted_*` reflects the
old pipeline. 162 labeled by Claude (notes `AI:`), 18 genuinely ambiguous
rows left blank for the owner — label them with
`analysis/golden_set/label_v2_owner.html`, then merge the download back.

What v2 established (numbers from `mix ls.golden_reclassify --ml`):

- **The classifier-v2 gain replicates out-of-sample**: precision of shipped
  labels 38.2% → 57.1% on data none of the changes ever saw (in-sample v1
  said 46.1% → 56.7%). Coverage lands at ~46% in both sets.
- **Junk is worse than v1 measured**: 35% of alive-filtered rows (v1: 23%).
- **String-based junk rules do not generalize**: 7/52 out-of-sample recall.
  v2 surfaced ~12 NEW parking/hosting templates (Namecheap, Porkbun,
  Aftermarket.eu, EffectiveNames, Miss Hosting, HostGator, Hoststar,
  ISPConfig, GoDaddy coming-soon, Webador, SprySite, demo-store banners).
  Next junk iteration must be structural — near-duplicate body detection
  across domains (one template = thousands of domains) — not more strings.
- **The revenue estimator matches brand names**: drmartensrepairs.com (a
  repair shop) predicted $1B+; caissedequebec.com and two Desjardins vanity
  domains likewise. High-bracket predictions are contaminated by
  brand-string association, and 6 of 10 rows predicted ≥$100M were junk
  pages or vanity redirects.
- **Known false-junk residual**: `"empty"` fires on bot-walled giants that
  serve a blank 200 to the HTTP tier (Transamerica, Zurich.de, parking.com).
  Those rows are hollow anyway; the browser lane re-fetch clears the flag.
  Keep routing `"empty"` to the browser lane, never exclude it by default.

## Distillation v1 (2026-08-14) — teacher labels + trained head

2,200 prod domains teacher-labeled (Haiku full pass + Sonnet consensus on
uncertain rows + web-verified revenue for 47 high-bracket domains) and
distilled into a 13-class logistic head over the existing MiniLM embeddings
(`LS.ML.Classifier.embed_batch/1`). On the owner-labeled golden holdout the
head's confidence is CALIBRATED: conf≥0.5 → 68% precision, conf≥0.7 → 91%.
Dataset: `analysis/distill/` (git) + `ls.ml_teacher_labels` on prod CH
(daily backup). Head: `priv/ml/head_v1.json`. Full method + rules in
`analysis/distill/README.md`. Runtime integration ships separately with
before/after golden numbers.

## Distillation v2 (2026-08-17) — 17 classes for real-world organizations

1,962 new domains (gov/edu/org/industrial/finance over-sampled, zero overlap
with v1 or golden) labeled Haiku-first with a Sonnet second opinion on all
752 uncertain/trap rows. Head v2 adds **Government, Nonprofit, Manufacturer,
FinancialInstitution** — the classes whose absence made nih.gov "SaaS@0.62"
and left cisco.com as least-wrong SaaS. On the expanded 71-row holdout
(51 owner + 20 AI new-class rows): conf≥0.6 → 86% precision, conf≥0.7 → 89%.
`.gov/.mil` are now deterministic `Government@0.95` in the heuristic tier
(they are legally restricted TLDs; no scoring or ML needed) — a *label*,
not a business: sellable-lead surfaces must not treat Government rows as
prospects, but similar-site widgets should keep them. Head:
`priv/ml/head_v2.json` (v1 stays as rollback). Labels:
`teacher_labels_v2_2026-08-17.jsonl` + dataset='distill_v2_2026-08-17' in CH.

## Golden v3 + head emission policy (2026-08-18)

Golden v3: 711 rows (see `analysis/golden_set/README.md`) — dual-labeler
protocol, 84% inter-labeler agreement, 59 Fable-adjudicated disputes,
273 evidence-backed revenue truths. Frozen in its own commit BEFORE tuning.

What it taught us, and what shipped from it:

- **Head emission policy** (`LS.ML.Head.shippable?/2`): head-emitted
  Government (31-50% precision) and FinancialInstitution (29-38%) are
  blocked — real government sites come from the deterministic TLD rule;
  Media needs prob ≥ 0.8; Marketplace/Newsletter/Community stay blocked.
  Shipped-ML precision on v3: 60% → 83% at 29% coverage.
- **Revenue: the estimator WON.** Retrained revenue heads (4k teacher
  brackets, with and without class features) scored 42-45% exact-bracket on
  v3's 126 embeddable truth rows; the heuristic estimator scored **83.9%**
  (92.9% within-one). The 2026-08-14 "head beats estimator" result held only
  on the brand-contaminated $100M+ slice (already fixed by the demotion
  backfill). Teacher labels contain ZERO verified $100M+ rows, so a learned
  revenue model has nothing to learn the top brackets from. Revenue head v2
  was NOT shipped. Next real lever: web-verified high-bracket truth
  (needs a fresh session's search budget), and estimator coverage on the
  rows where it currently predicts nothing.
- **Verified truth, two ways (2026-08-18).** (a) The web-verification
  handoff (`analysis/revenue_verify/`) added 30 evidence-backed revenue
  truths to golden v3 (306 total) and 27 verified training rows to
  `ls.ml_teacher_labels` (teacher=`web_verify`, incl. the first three
  $100M-$1B training rows) — every search logged and dated under
  `results/`. (b) Pipeline 3 (`LS.Verification`, docs/pipelines.md) now
  ingests Wikidata, SEC EDGAR, Companies House, Sirene/INPI and YC into
  `verified_facts` and `businesses.verified_*`. Golden v3 stays the
  untouched judge: whether verified facts let a revenue model or a revised
  estimator beat the heuristic's 83.9% / 92.9% is a separate, measured
  change — nothing here tunes the estimator.
- Junk from the head is 32/32 at conf≥0.6 on v3 — a future increment could
  let high-confidence head-Junk feed `is_junk`, but only after the
  browser-lane path stops feeding bot-walled giants into the text tier.

## Where this is going (agreed 2026-08-07)

Priority order, cheapest-first: junk gate everywhere → per-class threshold
calibration from golden labels → LLM (Haiku, Batch API) only for
valuable-but-uncertain domains where heuristic and MiniLM disagree, distilling
LLM labels back into the embedding tier → revenue calibration against golden
labels, later against free registries (Sirene, Companies House) → drift
dashboards in Metabase.
