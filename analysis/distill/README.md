# Distillation datasets — teacher labels + trained heads

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
