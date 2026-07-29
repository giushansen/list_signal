-- BOTH PIPELINES side by side: is data flowing right now?
SELECT
  'discovery' AS pipeline,
  (SELECT count() FROM domains_history)                                            AS total_rows,
  (SELECT count() FROM domains_history WHERE enriched_at >= now() - INTERVAL 1 MINUTE) AS per_min,
  (SELECT count() FROM domains_history WHERE enriched_at >= now() - INTERVAL 1 HOUR)   AS per_hour
UNION ALL
SELECT
  'enrichment',
  (SELECT count() FROM biz_enrichment),
  (SELECT count() FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 1 MINUTE),
  (SELECT count() FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 1 HOUR)
