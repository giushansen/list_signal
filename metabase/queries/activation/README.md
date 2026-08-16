# Activation & first-dollar queries (RevOps)

These run against the **SQLite snapshot** (`listsignal.db` datasource on the prod
Metabase at metabase.listsignal.com — it reads `/var/lib/metabase-data/listsignal.db`,
synced hourly), NOT the ClickHouse connection the other `queries/*.sql` use.
SQLite dialect: `julianday`, `strftime`, window functions.

Why these and not signups: signups are vanity for a self-serve data product. The
funnel that predicts revenue is **signup → first search → first export → paid**,
plus **weekly active searchers** as the North-Star usage metric. `search` audit
events exist since 2026-08-16 (deploy of the async search audit) — cohorts before
that date will show 0 searches, which is a data-start artifact, not churn.

The owner account (`fourretg@gmail.com`) and manually-comped plans
(`stripe_subscription_id = 'manual_override'`) are excluded everywhere, so the
numbers only ever count strangers and real money.

| file | question it answers |
|---|---|
| `30_weekly_activation_funnel.sql` | of each week's signups, how many searched / exported within 7 days? |
| `31_weekly_active_searchers.sql` | North Star: distinct accounts searching per week |
| `32_time_to_value.sql` | how long from signup to first search / first export? |
| `33_first_dollar.sql` | who actually paid, when, and how long after signup? |
| `34_most_active_accounts_30d.sql` | engagement + abuse: events per account, 30d |

Create each as a **Native query** on the `listsignal.db` (SQLite) datasource in a
"RevOps" collection. The existing `scripts/load_metabase.sh` targets the local
ClickHouse-only Metabase and does not load these.
