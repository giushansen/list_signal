-- Time-to-value: minutes from signup to first search and first export.
-- Median via window functions (SQLite >= 3.25). Target: first search < 10 min —
-- if the median is hours, the empty-dashboard moment is eating conversions.
WITH ttv AS (
  SELECT
    u.email,
    ROUND((julianday(fs.at) - julianday(u.inserted_at)) * 1440, 1) AS min_to_search,
    ROUND((julianday(fe.at) - julianday(u.inserted_at)) * 1440, 1) AS min_to_export
  FROM users u
  LEFT JOIN (SELECT user_id, MIN(inserted_at) AS at FROM audit_events
             WHERE event = 'search' GROUP BY user_id) fs ON fs.user_id = u.id
  LEFT JOIN (SELECT user_id, MIN(inserted_at) AS at FROM audit_events
             WHERE event = 'csv_export' GROUP BY user_id) fe ON fe.user_id = u.id
  WHERE u.email <> 'fourretg@gmail.com'
),
ranked AS (
  SELECT min_to_search,
         ROW_NUMBER() OVER (ORDER BY min_to_search) AS rn,
         COUNT(*) OVER () AS n
  FROM ttv WHERE min_to_search IS NOT NULL
)
SELECT
  (SELECT COUNT(*) FROM ttv)                                        AS users_total,
  (SELECT COUNT(*) FROM ttv WHERE min_to_search IS NOT NULL)        AS ever_searched,
  (SELECT AVG(min_to_search) FROM ranked WHERE rn IN ((n+1)/2, (n+2)/2)) AS median_min_to_first_search,
  (SELECT COUNT(*) FROM ttv WHERE min_to_export IS NOT NULL)        AS ever_exported,
  (SELECT AVG(min_to_export) FROM ttv WHERE min_to_export IS NOT NULL)  AS avg_min_to_first_export;
