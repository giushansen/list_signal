# Distillation datasets — teacher labels + trained heads

## v4 (2026-10-19) — encoder bake-off, e5-small wins, head v4

The v3 note ended with "the next real gain needs a better encoder than
MiniLM". Measured on golden v7 (308 rows, labeled 2026-10-19, none of
them in any training set) with heads trained on the same 6,129 rows
(teacher v1-v3 plus golden v1-v6 truth, text = `title h1 meta body +
LS.ML.Features hint` exported by `export_text.exs`, StandardScaler +
LogisticRegression C=0.05 balanced, picked by 5-fold CV):

| encoder | params / dims | v7 raw | conf >= 0.7 | conf >= 0.9 | SaaS >= 0.8 |
|---|---|---|---|---|---|
| MiniLM-L12-v2 (shipped head v3, as is) | 118M / 384 | 56.7% | cov 20%, prec 89.3% | | |
| MiniLM-L12-v2, retrained | 118M / 384 | 52.5% | cov 45%, prec 75.8% | cov 18%, 82.7% | 10/12 |
| multilingual-e5-small, 512 tokens | 118M / 384 | 62.1% | cov 51%, prec 84.0% | cov 29%, 89.2% | 22/25 |
| multilingual-e5-small, 128 tokens / 500 chars (runtime shape) | 118M / 384 | 61.3% | cov 60%, prec 80.4% | cov 33%, 88.2% | 27/30 |
| bge-m3 | 568M / 1024 | 63.1% | cov 66%, prec 81.2% | cov 44%, 88.0% | 21/26 |
| gte-multilingual-base | 305M / 768 | crashed in the encoder on CPU and MPS, not scored | | | |

Same architecture family (BERT, 12 layers, 384 hidden) and the same
output size as MiniLM, so Bumblebee loads it with the existing serving
code; the only runtime differences are the repo name, the `query: `
prefix e5 is trained with (added in `sanitize_text/1` so labels and texts
get it alike), and the industry cosine mapping, recalibrated because e5
cosines sit in 0.83-0.87 where MiniLM's sat in 0.22-0.49. Embeddings from
Bumblebee and sentence-transformers agree to cosine 1.000 on three test
strings. bge-m3 buys one point of raw accuracy for 5x the parameters; it
does not fit the 1-core workers.

- `bakeoff_2026-10-19.py` — the comparison above (embeddings cached per
  encoder; coverage-matched precision printed alongside thresholds,
  because raw logistic confidences are not comparable across encoders).
- `train_head_v4.py` — the shipped head: e5 at the runtime shape (128
  tokens, 500 chars), scaler folded into coef/intercept, written to
  `priv/ml/head_v4.json`; also prints the industry cosine percentiles the
  new `normalize_score/1` mapping was set from.
- `export_text.exs` — `mix run --no-start export_text.exs ROWS.jsonl
  OUT.jsonl`: the exact hinted text the runtime embeds, from enrich_log
  rows merged with `businesses` counts (product_count, job_count,
  sitemap_urls).
- Per class at conf >= 0.7 on v7 (correct/calls, e5 runtime shape): SaaS
  30/35, Ecommerce 19/25, Agency 24/28, Consulting 12/15, LocalBusiness
  21/23, Manufacturer 5/5, Junk 9/9, Tool 4/7, Education 2/6.
- The production floors (`LS.Pipeline.@ml_class_floor`) were set for
  head v3 and are kept: SaaS 0.95 is the owner's call from 2026-10-06
  and the pinned test says so. On v7 the e5 head reads SaaS 27 of 30 at
  0.8 and 16 of 18 at 0.9; lowering the floor is a separate decision.

## v3 (2026-09-06) — structured hints, Fable teacher, +740 domains (in progress)

- `teacher_labels_v3_2026-09-06.jsonl` — the remainder of the golden v5
  pool (740 domains, same strata: Shopify/SaaS/online-heavy, zero overlap
  with any golden set). Teacher: Claude Fable 5.1 agents (`teacher:
  "fable"`) for batches 0-6, Sonnet (`teacher: "sonnet"`) for 7-14 after
  the Fable usage limit; each domain's homepage fetched live plus the
  stored hints. Method validated in v1 (Haiku 67% vs Sonnet 63% against
  owner labels, statistically equal).
- **The text the head embeds changed**: `LS.ML.Features.hint/1` appends
  platform, apps, mail setup (provider + DMARC), catalog, jobs and page
  counts as a fixed-vocabulary sentence, in `LS.Pipeline` and in
  `embed_labels.exs` alike. Every embedding file used for v3 was produced
  AFTER that change; v1/v2 embeddings are not comparable.
- `train_head_v3.py` — same contract as v2, evaluates per golden set.
- **Result (pass 2: v1 + v2 + 350 v3 labels = 4,509 rows), measured on all
  998 embeddable golden rows (v3 + v4 + v5), never trained on:**

  | | head v2 (shipped, no hint) | head v3 (hint) |
  |---|---|---|
  | raw accuracy | 48.0% | 51.7% |
  | conf >= 0.5 | cov 43%, prec 67.5% | cov 41%, prec 72.0% |
  | conf >= 0.7 (shipped tier) | cov 19%, prec 79.3% | cov 19%, prec 83.8% |
  | golden v5 (Shopify/SaaS-heavy) | 49.1% | 57.5% |

  A/B without the hint on the same v3 labels: 47.6% raw, 82.2% at 0.7, so
  the gain is the hint, not the extra labels. `priv/ml/head_v3.json`
  shipped; v2 stays as rollback (switch `@weights_path` AND remove the
  hint together, never one without the other).
- **v3.1 check (all 740 v3 labels, 4,899 rows):** 51.0% raw, 70.1% at 0.5,
  83.7% at 0.7, v5 58.4%. Within noise of pass 2 (n=998, about 1.5 points
  of error), so the shipped weights were kept rather than churned. The
  Sonnet half of the labels adds training data for the next head, not
  accuracy for this one; the next real gain needs either a better encoder
  than MiniLM or owner-adjudicated labels on the classes that are still
  weak (Tool, Marketplace, Directory, Community, Government at 8/50).

## v2 (2026-08-17) — 17 classes, +1,962 domains

Head v2 (`priv/ml/head_v2.json`, sha256 a21de941…) adds four classes the
owner asked for after nih.gov/cisco.com surfaced as "SaaS" in similar-business
widgets: **Government, Nonprofit, Manufacturer, FinancialInstitution**.
Real-world organizations now get a truthful label ("classified, just not as
a business"), so similar-site lookups stay inside their own kind.

- `teacher_labels_v2_2026-08-17.jsonl` — 1,962 NEW domains (sampled to
  over-represent gov/edu/org/industrial/finance strata; zero overlap with v1
  or any golden set). Provenance per row: `teacher` (sonnet | haiku) — all
  752 low-confidence/trap-class rows got a Sonnet second opinion (Sonnet
  overrode Haiku on 17%); `haiku_business_model` preserved on overridden rows.
- `teacher_instructions_v2.md` — the 17-class taxonomy + boundary rules
  (`.gov/.mil ⇒ Government`, fintech SaaS vs mortgage broker, etc.).
- `golden_truth_v2_2026-08-17.json` — 79-row eval holdout: 51 owner labels +
  28 AI-labeled rows for the new classes (8 of those are bot-walled with no
  fetchable text, so embedding evals run on 71).
- `train_head_v2.py` — trains on v1+v2 merged (4,158 rows), evals on the
  holdout. Shipped config C=2.0, class_weight=balanced (won the sweep).
- **Numbers** (71-row holdout, never trained on): 50.7% raw 17-class
  accuracy; conf≥0.6 → 86% precision @ 30% coverage; conf≥0.7 → 89% @ 25%.
  Raw accuracy is not comparable to v1's 13-class 47% — the v2 holdout has
  more classes and harder rows; calibration is what the runtime relies on.
- Runtime change shipped with it: `.gov/.mil` are now deterministically
  `Government@0.95` in `BusinessClassifier` (was: never-classify), and the
  pipeline's gov/mil ML carve-out is gone (the 0.95 clears the ML gate).
- Prod ClickHouse: rows appended to `ls.ml_teacher_labels` with
  dataset='distill_v2_2026-08-17'.

## v1 (2026-08-14) — original 13-class dataset + head

The first trained classification head for ListSignal: 2,200 prod domains
labeled by Claude teachers, distilled into a 13-class logistic head over the
MiniLM embeddings the ML tier already computes. Built entirely from stored
`domains_current` text (no recrawling) via Claude Code subagents on the
owner's plan (no API key).

## What's here

- `teacher_labels_v1_2026-08-14.jsonl` — THE dataset. One row per domain:
  `business_model` (12 classes + Junk), `industry`, `revenue_bracket`,
  `employees_bracket`, `confidence`, plus provenance: `teacher`
  (haiku | consensus), `haiku_bm` (first-pass label), `teachers_agree`,
  `revenue_source`/`revenue_verified` (web-search-verified rows only).
  Reusable with ANY future embedding model — the labels are model-agnostic.
- `../..//priv/ml/head_v1.json` — trained head: 13×384 coefficients +
  intercepts, `sha256 3eaf0621…`. 100KB. Loaded at runtime (integration
  pending); regenerate with `train_head.py`.
- `train_head.py` / `embed_labels.exs` — full training pipeline:
  embed via `LS.ML.Classifier.embed_batch/1`, train sklearn logistic
  regression, eval on the owner-labeled golden holdout.
- `teacher_instructions.md` — the exact labeling prompt (taxonomy +
  boundary decision rules from the golden-set adjudications).

## How it was built (method)

1. **Teacher validation first**: Haiku and Sonnet each labeled the 51
   owner-labeled golden rows. Haiku 67%, Sonnet 63% — statistically equal,
   so the limiter is taxonomy boundary ambiguity, not model intelligence.
   When the two models agree (78% of rows) they match the owner 72%.
2. **Sample**: 2,200 stratified domains from `domains_current` (26 strata ×
   75 + 250 high-predicted-revenue; golden domains excluded — they stay
   eval-only forever).
3. **Haiku full pass** (44 checkpointed batches), then **Sonnet second
   opinion** on the 487 low-confidence/trap-class rows (agreed with Haiku on
   64% of those); Sonnet wins where present.
4. **Revenue deep-dive**: 120 high-bracket domains web-searched; 47 got a
   source-verified bracket (zoominfo/crunchbase/annual reports). Agents
   refused to attribute near-name matches (redegazeta.com parked vs
   redegazeta.com.br broadcaster) — `verified` is trustworthy.
5. **Train + eval**: 5-fold CV vs teacher 60%; on the owner-labeled golden
   holdout (n=51, never trained on): 47% raw 13-class accuracy, and
   **calibrated confidence** — conf≥0.5 → 68% precision, conf≥0.7 → 91%
   precision at 22% coverage. (n=51 ⇒ ±14% error bars; owner labels carry
   known boundary noise, so raw accuracy is pessimistic.)

## Storage / versioning / backup

- **Git** (this directory + `priv/ml/head_v1.json`): versioned, pushed to
  GitHub — that is the canonical copy and the offsite backup.
- **Prod ClickHouse** `ls.ml_teacher_labels` (2,200 rows,
  dataset='distill_v1_2026-08-14'): queryable next to the product data and
  included in the daily CH backup (`/home/ls/backup.sh`).
- The MiniLM encoder itself is NOT here — it is ~458MB in
  `/home/ls/.cache/bumblebee` on each of the 9 nodes, re-downloadable from
  HuggingFace. Since 2026-08-18 it is ALSO tarred on the master at
  `/home/ls/backups/bumblebee_minilm_20260818.tar` (one-off, outside the
  rotation — the artifact never changes), so a HuggingFace takedown cannot
  orphan the embeddings. Restore: `tar -xf bumblebee_minilm_20260818.tar -C
  /home/ls/.cache/`. Explicit `revision:` pin in `Bumblebee.load_model` is
  still open (cache filenames are hashed; pin when next touching the loader).
- Golden eval pages are snapshotted in git since 2026-08-18
  (`analysis/golden_set/pages_v2_2026-08-17.tar.gz`) — the scratchpad copy
  was wiped twice by tmp housekeeping, and a re-fetched snapshot is NOT
  comparable to the one the BEFORE numbers were measured on.

## Rules (same discipline as the golden sets)

- Golden rows never enter training. The owner-labeled holdout is the only
  accuracy claim that counts.
- Grow v2 from disagreements (the 174 haiku-vs-sonnet conflicts are the
  hardest examples — prime candidates for owner adjudication).
- A head change ships with before/after golden-holdout numbers, like every
  classifier change.
