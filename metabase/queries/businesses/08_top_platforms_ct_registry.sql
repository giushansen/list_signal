-- CT-detected platforms: who hosts the web's new certificates.
-- source='seed' = curated apexes; source='auto' = learned by the velocity
-- heuristic (>=20 certs/hour sustained for 1h+, or >=100 subdomains).
SELECT domain, platform_name, category, source, detection_reason,
       cert_count, round(cert_rate_per_hour, 1) AS certs_per_hour,
       max_subdomain_count, estimated_hosted_domains,
       first_detected, last_seen
FROM ls.platforms FINAL
ORDER BY estimated_hosted_domains DESC, cert_count DESC
LIMIT 100
