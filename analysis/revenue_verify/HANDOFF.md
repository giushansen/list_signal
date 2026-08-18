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

## Outcome (executed 2026-08-18, Fable 5 + 11 Sonnet agents)

Budget: 153 WebSearch calls (47 held in reserve) + 282 WebFetch. Every call
is logged, dated, in `results/*_searches.jsonl`; every domain's verdict with
evidence in `results/*.jsonl` (one line per domain, `verified_at`). Reuse the
logs before searching any of these 170 domains again.

- **Training (50 rows, all teacher-guessed $10M-$100M):** 27 verified
  (18 with a revenue bracket): $100M-$1B ×3, $10M-$100M ×7, $1M-$10M ×6,
  <$1M ×2; employees 1-10 ×5, 11-50 ×6, 51-200 ×8, 201-1000 ×4, 1000+ ×1.
  Only 7/18 of the teacher's "$10M-$100M" guesses held — the teacher
  over-guesses the mid bracket. Persisted to `ls.ml_teacher_labels` as
  teacher='web_verify', verified=1, dataset='distill_v2_2026-08-17'
  (a distinct `teacher` so the ReplacingMergeTree key never replaces the
  haiku/sonnet rows). Unknown brackets are stored as '' — never 'unknown'.
- **Golden gaps (120 rows):** 49 verified; 30 got `true_revenue`
  (<$1M ×20, $1M-$10M ×3, $10M-$100M ×7), 19 employees-only (recorded in
  `notes`, `true_revenue` left blank), 71 unverified. Second-pass review
  removed 5 revenue claims the agents had accepted: parent-company
  revenue on a brand domain (instyle.com), a ZoomInfo estimate for a
  government agency (lslga.org), estimates straddling a bracket boundary
  (360realtors.com, paramountconductors.com) and a 14-year-old 990
  (portlandrescuemission.org). Golden v3 now has 306 revenue truths.
- Not filled on purpose: the estimator's numbers were NOT re-run in this
  change (label-only commit; see docs/data-quality.md rule 1).
