# Backfill v1 (2026-08-15) — junk + head class + revenue demotion on `businesses`

Ran once against backup `prod_20260814_154004.tar`. Pipeline: export stored
text from `domains_current` → laptop compute (`backfill_compute.exs`: THE
production `junk_reason/1` over 20.27M rows + candidate selection;
`backfill_embed.exs`: MiniLM + both heads) → Join-engine helper tables
(`ls.bf1_junk/bf1_class/bf1_rev`, kept for audit) → `apply_backfill.sh`:
16-shard guarded mutations, `mutations_sync=1`.

Applied (verified in prod):
- is_junk: +92,103 flags (total now 111,198: placeholder 54.6k, parked 46.7k,
  empty 9.9k, scam 2)
- business_model: +32,304 rows classified by the head at conf >= 0.5
  (first increment — 150k candidates of ~3M; rerun with higher HEAD_CAP to continue)
- estimated_revenue: 16,986 brand-contaminated "$100M+" rows demoted to the
  revenue head's bracket at conf >= 0.5

Guards (in compute AND re-checked in SQL): junk only where is_junk='',
class only where business_model=''/conf<0.55, revenue only demoting the
$100M-$1B/$1B+ band; export filter guarantees no row without stored signals
is ever branded (the h1-incident rule). Gotchas encountered, for the next
run: `IO.binwrite` not `IO.write` (CH text contains invalid UTF-8 →
:no_translation), and `joinGet` inside mutations needs database-qualified
table names ('ls.bf1_*').

Freshness note: a fresh crawl always outranks a backfill (compactor
re-derives from history), and a FULL businesses rebuild regresses
backfilled rows that haven't been recrawled yet — rerun this after any
`rebuild_all` until the recrawl cycle has passed.
