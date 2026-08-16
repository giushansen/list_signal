-- Engagement AND abuse in one view: events per account, last 30 days.
-- A healthy paying prospect and a scraper look identical here except for
-- volume — sort by total and eyeball the top.
SELECT
  COALESCE(email, '(no email)')                       AS account,
  SUM(event = 'search')                               AS searches,
  SUM(event = 'csv_export')                           AS exports,
  SUM(event = 'csv_downloaded')                       AS downloads,
  SUM(event LIKE 'stripe_%')                          AS billing_events,
  COUNT(*)                                            AS total,
  MIN(inserted_at)                                    AS first_seen,
  MAX(inserted_at)                                    AS last_seen
FROM audit_events
WHERE inserted_at >= datetime('now', '-30 days')
GROUP BY email
ORDER BY total DESC
LIMIT 25;
