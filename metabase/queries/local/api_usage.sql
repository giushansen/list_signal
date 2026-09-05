-- API/MCP usage: who, when, how, what was read.
-- Source: api_request_log (one row per successful call, async-written).

-- Daily calls by user and surface (the adoption picture)
SELECT toDate(ts) AS day, email, plan, surface, count() AS calls,
       sum(result_count) AS rows_read
FROM api_request_log
WHERE ts > now() - INTERVAL 30 DAY
GROUP BY day, email, plan, surface
ORDER BY day DESC, calls DESC;

-- What is being read: endpoints and tools
SELECT endpoint, surface, count() AS calls, uniqExact(email) AS users,
       sum(result_count) AS rows_read
FROM api_request_log
WHERE ts > now() - INTERVAL 30 DAY
GROUP BY endpoint, surface
ORDER BY calls DESC;

-- Which companies people look up (demand signal for the dataset)
SELECT target AS domain, count() AS lookups, uniqExact(email) AS distinct_users
FROM api_request_log
WHERE target != '' AND ts > now() - INTERVAL 30 DAY
GROUP BY target ORDER BY lookups DESC LIMIT 100;

-- Which filters people search with (what the market wants from us)
SELECT filters, count() AS searches
FROM api_request_log
WHERE filters != '' AND ts > now() - INTERVAL 30 DAY
GROUP BY filters ORDER BY searches DESC LIMIT 100;

-- Free users nearing quota = the upgrade conversation list
SELECT email, plan, count() AS calls_this_month
FROM api_request_log
WHERE ts >= toStartOfMonth(now()) AND plan = 'free'
GROUP BY email, plan
HAVING calls_this_month > 500
ORDER BY calls_this_month DESC;
