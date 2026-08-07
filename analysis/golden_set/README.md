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

Open the CSV in Numbers/Sheets. For each row, click the `url`, look for
10–20 seconds, and fill the blank columns:

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

## What happens with it

Once filled, Claude scores precision/recall per class and per confidence band,
recalibrates the confidence thresholds, fixes the worst classifier layers, and
this file becomes the regression fixture (`test/`) so future classifier changes
are measured, not vibes. v2 of the set grows from the disagreements.
