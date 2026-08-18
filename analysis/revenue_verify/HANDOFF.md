# Revenue/HR web-verification handoff (staged 2026-08-18)

Run this in a session with a FRESH WebSearch budget (200 calls; it is
per-harness-session and does not reset with plan credits).

## Goal
Web-verified revenue + employee brackets. Today's measured state
(docs/data-quality.md): the heuristic estimator scores 83.9% exact-bracket on
golden v3; learned revenue heads lost (42-45%) because the teacher labels
contain ZERO verified $100M+ rows. Verified truth is the only unlock.

## Inputs (this directory)
- `rev2_0.txt` … `rev2_4.txt` — 50 high-bracket TRAINING domains (from
  teacher_labels_v2). Verified results go to `ls.ml_teacher_labels` with
  verified=1, source=<url>, dataset='distill_v2_2026-08-17' (INSERT new rows;
  the table is append-only for provenance).
- `golden_gaps.txt` — 120 golden-v3 EVAL rows lacking `true_revenue`,
  best-ranked first. Verified results go into
  `analysis/golden_set/golden_set_v3_2026-08-18.csv` (`true_revenue` +
  evidence in `notes`) as a LABEL-ONLY commit — never in the same change as
  model tuning.

## Protocol (proven 2026-08-14; agents refused bad matches — keep it that way)
- 1-2 WebSearch queries/domain: "<company> revenue employees zoominfo OR
  crunchbase OR annual report". Budget: ~170 searches max, keep headroom.
- STRICT identity rule: attribute data only if the source clearly refers to
  the company operating THAT domain. Similar name on another domain = NOT a
  match -> unverified. Never guess, never copy system predictions.
- Output JSONL per batch: {"domain","revenue_bracket","employees_bracket",
  "source","verified":bool,"note"} — brackets: <$1M|$1M-$10M|$10M-$100M|$100M+
  and 1-10|11-50|51-200|201-1000|1000+ or "unknown".
- Sonnet agents, ≤6 in parallel (search budget is shared session-wide).

## After verification
1. Persist (CH + golden CSV label-only commit, push).
2. Only THEN consider retraining revenue estimation, with golden v3 as the
   untouched eval. Ship nothing that does not beat the estimator's 83.9%
   exact / 92.9% within-one on the same rows.
