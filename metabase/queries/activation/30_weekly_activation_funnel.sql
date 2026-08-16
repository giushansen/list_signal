-- Weekly signup cohorts and what they did in their first 7 days.
-- Activation = ran at least one search; the deeper cut = exported.
-- Search events exist only since 2026-08-16 (audit deploy) — earlier cohorts
-- legitimately show 0.
WITH cohort AS (
  SELECT id, email, inserted_at
  FROM users
  WHERE email <> 'fourretg@gmail.com'
),
first_search AS (
  SELECT user_id, MIN(inserted_at) AS at
  FROM audit_events WHERE event = 'search' GROUP BY user_id
),
first_export AS (
  SELECT user_id, MIN(inserted_at) AS at
  FROM audit_events WHERE event = 'csv_export' GROUP BY user_id
)
SELECT
  strftime('%Y-W%W', c.inserted_at)                                   AS signup_week,
  COUNT(*)                                                            AS signups,
  SUM(fs.at IS NOT NULL
      AND julianday(fs.at) - julianday(c.inserted_at) <= 7)           AS searched_7d,
  SUM(fe.at IS NOT NULL
      AND julianday(fe.at) - julianday(c.inserted_at) <= 7)           AS exported_7d,
  ROUND(100.0 * SUM(fs.at IS NOT NULL
      AND julianday(fs.at) - julianday(c.inserted_at) <= 7)
      / COUNT(*), 1)                                                  AS activation_pct
FROM cohort c
LEFT JOIN first_search fs ON fs.user_id = c.id
LEFT JOIN first_export fe ON fe.user_id = c.id
GROUP BY signup_week
ORDER BY signup_week DESC;
