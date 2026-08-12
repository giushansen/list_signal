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
