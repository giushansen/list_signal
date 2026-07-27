-- Silent-failure detector: per-stage failure rates, hourly, last 48h.
--
-- IMPORTANT: each ratio is measured against the population where that stage
-- ACTUALLY RUNS, not against all rows. The pipeline is a funnel — HTTP only
-- runs for 42 high-value TLDs, classification only on a 2xx body, BGP only on
-- a crawled host — so naive "empty column / all rows" ratios sit at 0.7-0.95
-- permanently and drown out the real signal. These denominators don't.
--
-- Funnel context (not failures): rows, http_attempt_rate.
-- Real failure rates: everything with a _of_ suffix.
SELECT
    toStartOfHour(enriched_at)                                          AS hour,
    count()                                                             AS rows,

    -- context: how much of the stream we even try to crawl (TLD gate)
    round(avg(http_status IS NOT NULL OR http_error != ''), 3)          AS http_attempt_rate,

    -- DNS runs on everything, so this denominator is all rows
    round(avg(dns_a = '' AND dns_cname = ''), 3)                        AS dns_unresolved,

    -- of crawls we attempted, how many errored (nxdomain, rate_limited, TLS…)
    round(avgIf(http_error != '',
                http_status IS NOT NULL OR http_error != ''), 3)        AS http_fail_of_attempted,

    -- of crawls that returned a status, how many were 5xx
    round(avgIf(http_status >= 500, http_status IS NOT NULL), 3)        AS http_5xx_of_status,

    -- classifier only sees 2xx bodies
    round(avgIf(business_model = '',
                http_status BETWEEN 200 AND 299), 3)                    AS unclassified_of_2xx,

    -- BGP only runs on hosts we successfully crawled; healthy = 0.000
    round(avgIf(bgp_asn_number = '', http_status IS NOT NULL), 3)       AS bgp_empty_of_crawled,

    -- of RDAP lookups actually attempted
    round(avgIf(rdap_error != '',
                rdap_registrar != '' OR rdap_error != ''), 3)           AS rdap_fail_of_attempted
FROM enrichments
WHERE enriched_at >= now() - INTERVAL 48 HOUR
GROUP BY hour
ORDER BY hour
