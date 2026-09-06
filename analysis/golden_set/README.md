# Golden set v1 — labeling instructions

`golden_set_v1_2026-08-07.csv` — 151 real domains sampled from prod `businesses`
(2026-08-07, alive sites only, seed `gset7` so the sample is reproducible).

## Why these rows

| bucket | what it measures |
|---|---|
| `model:<X>:high` (5/class) | precision of confident predictions — are they actually right? |
| `model:<X>:low` (5/class) | quality near the 0.55 cutoff — should the cutoff move? |
| `unclassified` (20) | recall — how many real, sellable businesses do we fail to classify? |
| `revenue:<bracket>` (6/bracket) | revenue estimator accuracy per bracket |

## How to label (≈60–90 min total)

**Easiest route — `label.html`.** Open it in a browser
(`open analysis/golden_set/label.html`): it already contains v1, shows one
domain at a time with a big "Open site" link, only asks the questions that
still apply, and saves progress in the browser as you go. When the bar hits
100% (or whenever you stop), hit **Download labeled CSV**, drop the file back
into `analysis/golden_set/`, and hand it to Claude. It reads any version of
the set via *Load other CSV*, so v2 needs no new tool.

Spreadsheet route, if you prefer: open the CSV in Numbers/Sheets, click each
`url`, look for 10–20 seconds, and fill the blank columns. Either way the
columns mean:

- **is_real_business** — `y` / `n`. `n` = parked, dead, default Shopify page,
  spam/PBN, personal blog, pure infrastructure.
- **model_ok** — `y` / `n`. Is `predicted_model` right? (Empty prediction on a
  real business = `n`.)
- **true_model** — only when `model_ok=n`: one of
  SaaS, Ecommerce, Agency, Consulting, Media, Education, Tool, Community,
  Marketplace, Newsletter, Directory. If nothing fits, invent a label and
  flag it in notes (taxonomy gaps are a finding, not an error).
- **industry_ok / true_industry** — same idea. Skip if you can't tell quickly.
- **true_revenue** — your gut bracket from the site (team page, LinkedIn if
  cheap to check): `<$1M`, `$1M-$10M`, `$10M-$100M`, `$100M-$1B`, `$1B+`.
  Leave blank if you truly can't tell — blank is better than a guess.
- **notes** — anything odd ("in French", "redirects to other domain",
  "actually a subsidiary of X").

Rules of thumb: label what the site IS, not what it uses (a store built on
Webflow is still Ecommerce). Don't overthink — your 15-second judgement is the
standard the pipeline is being graded against, and consistency matters more
than perfection.

## Status: v1 fully labeled (2026-08-12)

Rows 1–35 by the owner, rows 36–151 by Claude (notes prefixed `AI:`), 9
owner rows carry `AI-check:` disagreement flags awaiting owner adjudication.
Invented `true_model` labels used where the taxonomy has no fit:
`LocalBusiness` (10×), `Bank` (3×), `Manufacturer` (2×), `Insurance` (2×),
`Government`, `Nonprofit` — see docs/data-quality.md for what to do about
them. The set is now FROZEN: it is the measuring stick for classifier
changes, so do not relabel rows in the same change that tunes the
classifier — adjudications and corrections happen in label-only commits.

## What happens with it

Once filled, Claude scores precision/recall per class and per confidence band,
recalibrates the confidence thresholds, fixes the worst classifier layers, and
this file becomes the regression fixture (`test/`) so future classifier changes
are measured, not vibes. v2 of the set grows from the disagreements.

## v3 (2026-08-18) — 711 rows, all 17 classes, dual-labeler protocol

`golden_set_v3_2026-08-18.csv` = v1 (151) + v2 (180) carried verbatim +
28 AI new-class rows (2026-08-17) + **380 new rows** sampled seed `gv3`
(8 per hi/lo band of every one of the 17 predicted classes + junk/blocked/
high-revenue/unclassified strata; disjoint from all 4,162 training domains).

Labeling protocol (stronger than v1/v2): two INDEPENDENT Sonnet labelers —
A from stored content only, B a skeptic allowed to fetch the live site —
agreed on 84% (320/380); the 59 disagreements were adjudicated one-by-one
by Fable with written rationale in `notes`. House rules set during
adjudication (apply them to future rows): real-estate brokerages with local
presence → LocalBusiness; content-is-product → Media even when legally a
nonprofit (greenz.jp, projectcensored.org); doorway/redirect mirrors → junk;
personal portfolios → `Unclear`. 24 rows are `Unclear` (blank
`is_real_business`, excluded from scoring) — honest gaps, several marking
taxonomy holes: 3PL/logistics, venture builders/holding cos, gambling
operators, credit bureaus.

Revenue truth: 273 rows carry a `true_revenue` bracket, each with the
evidence quoted in `notes` (site-stated figures or unambiguous scale
markers). Never copied from the system's own prediction.

Baseline at freeze (prod predictions at sampling time, `mix ls.golden_eval`):
overall high-band accuracy 68.6%; yesterday's new classes all 100% on their
slices (Government 5/5, FinancialInstitution 5/5, Manufacturer 11/11,
Nonprofit 11/11, LocalBusiness 12/12); legacy trap classes still weak
(Marketplace 10%, Newsletter 19%, Tool 24%); revenue 70.5% exact-bracket
(n=258). Frozen BEFORE any model tuning, per the working agreement.
Eval page snapshots: `pages_v2_2026-08-17.tar.gz` (in git, because the
scratchpad copies were wiped twice).

## v4 (2026-08-21) — Shopify/SaaS-heavy, verified-truth cross-checked

`golden_set_v4_2026-08-21.csv` — **225 domains**, seed `gv4`, alive only
(`http_status=200`, `dns_alive=1`, `is_junk=''`), disjoint sampling from
`businesses`. Built to two goals the earlier sets did not target:

1. **≥ half Shopify + SaaS** (122 rows / 54%): the two models we sell most.
   Strata `shopify_ver/plain`, `saas_ver/plain`.
2. **Cross-checkable against pipeline-3 verified data** (170 rows / 76% carry
   an authoritative fact): each row's `notes` records the verified employees/
   revenue we hold from SEC EDGAR / Companies House / Wikidata / Sirene / YC,
   and where we have a **verified revenue figure the `true_revenue` is that
   figure** (authoritative, not a guess) — 9 rows. A `bigco_ver` stratum (30
   rows) adds larger verified companies ($10M–$1B+, 51–5000+ employees) so the
   estimator's weak high brackets are measured against real truth.

Labeling: a single **Haiku** pass (8 agents, homepage fetch + the verified
hint as scale evidence), raw labels kept in `gv4_labels/batch_*.jsonl` for
provenance. Notes prefixed `AI:`. Because 100% of the labels are LLM-authored,
treat v4 as *LLM-assisted* ground truth (like v1/v2) — strong for finding weak
classes and for the verified-revenue rows (which are authoritative), weaker as
the last word on any single model call. Owner spot-checks welcome before it
grades a shipped change.

Baseline at freeze (`mix ls.golden_eval`, prod predictions at sampling time):
- 206/225 scored (19 `Unclear`/blank). Junk rate 13.6%.
- **Model precision by class**: SaaS 78% (n=37), Education 69%, Agency 67%,
  **Ecommerce 44% (n=61)** — the Shopify-tech-→-Ecommerce trap: many are local
  services (LocalBusiness) or B2B manufacturers; Newsletter/Tool/Directory 0%.
- **Revenue estimator: 39.1% exact-bracket (n=23)** against verified truth —
  far below the 83.9% v3 headline, because this population (small registry-
  verified firms + a few large verified brands) is exactly where the heuristic
  estimator is weakest. This is the honest number a revenue model must beat on
  the domains we actually sell.

Frozen BEFORE any model/estimator tuning, per the working agreement.

## v5 (2026-09-06) — Shopify/SaaS/online-heavy, Fable-labeled, with employees

`golden_set_v5_2026-09-06.csv` — **320 domains**, sampled from `businesses`
(alive, `http_status=200`, `dns_alive=1`, `is_junk=''`, non-empty title) by
`cityHash64(concat(domain,'gv5'))` order within strata, every v1-v4 and
teacher-labeled domain excluded. Strata: shopify 110, saas 70, ecommerce
(non-Shopify) 40, online (Marketplace/Tool/Media/Newsletter/Community/
Directory) 45, bigco (verified $10M+/501+ or Tranco <= 50K) 30, offline 25.
The same pool's remainder (740 domains) became the distill v3 teacher set
(`analysis/distill/teacher_labels_v3_2026-09-06.jsonl`); the two never
overlap.

Labeling: Claude Fable 5.1 agents, one batch of 50 per agent, each domain's
homepage fetched live plus the stored HINTS (tech, apps, MX, DMARC, Shopify
product count, verified facts) as scale evidence; raw output in
`gv5_labels/batch_*.jsonl`. New column `true_employees`. Notes prefixed
`AI:` and record whether the fetch worked. 100% LLM-authored: LLM-assisted
ground truth, like v1/v2/v4.

Baseline at freeze (`mix ls.golden_eval`, prod predictions at sampling time,
all 320 rows): junk 15.6%; Ecommerce precision 68.5% (n=146), SaaS 63.5%
(n=52), Agency 57.1%, Media 45.5%, Consulting 41.7%; high-confidence band
76.5% (n=166) vs low 36.5% (n=104); revenue exact-bracket 69.3% (n=261).
Sampled and frozen BEFORE head v3 and the 2026-09-06 estimator signals
reached production (label-only commit).

Recurring pipeline errors the labelers flagged: Shopify carts on
LocalBusiness sites (bakery pickup, single bottle shop, takeaway) labeled
Ecommerce; "Community" used as a catch-all for small organisations; frozen
Shopify stores (HTTP 402) and "Opening soon" shells counted as businesses.
