-- North Star: distinct accounts that ran >= 1 search that week.
-- Searches correlate with value delivered; signups don't.
SELECT
  strftime('%Y-W%W', inserted_at) AS week,
  COUNT(DISTINCT user_id)         AS active_searchers,
  COUNT(*)                        AS searches
FROM audit_events
WHERE event = 'search'
  AND (email IS NULL OR email <> 'fourretg@gmail.com')
GROUP BY week
ORDER BY week DESC
LIMIT 26;
