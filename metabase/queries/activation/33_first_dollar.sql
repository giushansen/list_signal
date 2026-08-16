-- First-dollar: accounts that actually pay. Manual comps
-- (stripe_subscription_id = 'manual_override', see the plan-grant runbook) and
-- the owner are excluded — this must only ever count real money.
-- days_to_paid uses the subscription-created stripe audit event when present
-- (webhook events are recorded as 'stripe_<type>'), else falls back to NULL.
SELECT
  u.email,
  u.plan,
  u.inserted_at                                                   AS signed_up_at,
  se.first_paid_at,
  ROUND(julianday(se.first_paid_at) - julianday(u.inserted_at), 1) AS days_to_paid
FROM users u
LEFT JOIN (
  SELECT user_id, MIN(inserted_at) AS first_paid_at
  FROM audit_events
  WHERE event LIKE 'stripe_%'
    AND (event LIKE '%subscription.created%' OR event LIKE '%checkout%completed%')
  GROUP BY user_id
) se ON se.user_id = u.id
WHERE u.plan IN ('starter', 'pro')
  AND COALESCE(u.stripe_subscription_id, '') <> 'manual_override'
  AND u.email <> 'fourretg@gmail.com'
ORDER BY u.inserted_at;
