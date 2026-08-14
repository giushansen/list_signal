# Distillation dataset v1 (2026-08-14) — teacher labels + trained head

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
  `/home/ls/.cache/bumblebee` on each worker, re-downloadable from
  HuggingFace (pin + rsync + backup still a TODO in devops).

## Rules (same discipline as the golden sets)

- Golden rows never enter training. The owner-labeled holdout is the only
  accuracy claim that counts.
- Grow v2 from disagreements (the 174 haiku-vs-sonnet conflicts are the
  hardest examples — prime candidates for owner adjudication).
- A head change ships with before/after golden-holdout numbers, like every
  classifier change.
