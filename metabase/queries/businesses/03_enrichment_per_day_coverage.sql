-- Enrichment throughput + stage coverage per day.
SELECT toDate(enriched_at) AS day, count() AS enriched,
       countIf(render_engine = 'camoufox') AS via_browser,
       countIf(seo_score IS NOT NULL) AS seo_scored,
       countIf(perf_lcp_ms IS NOT NULL) AS with_perf,
       countIf(product_count > 0) AS catalogs,
       countIf(job_count > 0) AS with_jobs,
       countIf(hq_location != '') AS with_hq
FROM ls.biz_enrichment
GROUP BY day ORDER BY day DESC
