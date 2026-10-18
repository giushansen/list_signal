# Sales enablement

- `data-fact-sheet.md`: what the data is and is not, in numbers, for the
  claude.ai project and for anyone writing copy. Refresh monthly.
- `claude-project.md`: the project instructions, the connector setup and
  the first message of the sales and marketing chats.

## Refreshing the fact sheet

On the master (`ssh root@45.63.7.58`), `clickhouse-client --multiquery`
with these, then replace the numbers in the sheet:

```sql
SELECT count() AS businesses, countIf(business_model != '') AS labeled,
  countIf(length(http_emails) > 0) AS with_email, countIf(http_phone != '') AS with_phone,
  countIf(verified_revenue != '') AS verified_revenue, countIf(job_count > 0) AS hiring,
  countIf(is_shopify = 1) AS shopify, countIf(http_last_seen_at > now() - INTERVAL 90 DAY) AS fetched_90d
FROM ls.businesses WHERE is_junk = '';

SELECT business_model, count() FROM ls.businesses WHERE is_junk = '' AND business_model != '' GROUP BY 1 ORDER BY 2 DESC;

SELECT inferred_country, count(), countIf(length(http_emails) > 0) FROM ls.businesses
WHERE is_junk = '' AND inferred_country != '' GROUP BY 1 ORDER BY 2 DESC LIMIT 12;

SELECT field, change, count() FROM ls.changes_log WHERE changed_at > now() - INTERVAL 30 DAY GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 25;

SELECT countIf(ctl_first_seen_at > now() - INTERVAL 30 DAY) AS new_shopify_30d FROM ls.businesses WHERE is_shopify = 1 AND is_junk = '';
```

Label precision comes from the golden set (`docs/data-quality.md`); do
not invent a number for a class that was not measured.
