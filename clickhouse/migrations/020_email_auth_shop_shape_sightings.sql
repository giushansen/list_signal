-- ═══════════════════════════════════════════════════════════════════════════
-- 020 — email authentication records, Shopify store shape, and certificate
--       sightings that the 7-day crawl gate suppressed (2026-09-06)
--
-- STATUS: apply BEFORE deploying the release that writes these. Additive
-- only (ADD COLUMN IF NOT EXISTS / CREATE TABLE IF NOT EXISTS), safe on a
-- LIVE app: ClickHouse adds a sparse column in ~0.06s (measured 2026-07).
--
-- WHY
--   dns_dmarc / dns_bimi / dns_dkim: the revenue estimator's DMARC signal
--   read the apex TXT record since it was written; DMARC lives at
--   _dmarc.<domain>, so it never saw a policy and voted "micro" for every
--   domain. LS.DNS.EmailAuth now looks the three records up in the
--   discovery DNS stage, only for domains with MX. BIMI (trademark + VMC)
--   and the DKIM selectors in use (Microsoft 365, Mailchimp, HubSpot...)
--   are size and tooling signals no web page shows.
--
--   apps_deep + shop_*: Shopify apps beyond the homepage (theme app
--   extensions read from cdn.shopify.com/extensions/<id>/<handle>-<ver>/,
--   app proxies, HubSpot hubs), scanned on the homepage, the secondary pages
--   and the first product page during depth enrichment; the compactor
--   unions apps_deep into businesses.http_apps. shop_theme / theme store id
--   / currency / locale count / Plus say what kind of store it is.
--
--   ctl_sightings: the crawl gate (LS.Cluster.CrawlDedup) now guarantees a
--   business is fetched at most once every 7 days. A certificate seen in
--   between is no longer thrown away: issuer and subdomains land here. It
--   is NOT written to domains_history because domains_current is
--   newest-row-wins on that table and a certificate-only row would blank
--   the domain's DNS and HTTP data.
--
-- BACKFILL
--   All columns fill on the next crawl / depth pass; older rows hold '' /
--   NULL and every reader treats that as "unknown", never as "no".
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE ls.domains_history
  ADD COLUMN IF NOT EXISTS dns_dmarc LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS dns_bimi String DEFAULT '',
  ADD COLUMN IF NOT EXISTS dns_dkim LowCardinality(String) DEFAULT '';

ALTER TABLE ls.businesses
  ADD COLUMN IF NOT EXISTS dns_dmarc LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS dns_bimi String DEFAULT '',
  ADD COLUMN IF NOT EXISTS dns_dkim LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_theme LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_theme_store_id Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS shop_currency LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_locales Nullable(UInt8),
  ADD COLUMN IF NOT EXISTS shopify_plus Nullable(UInt8);

ALTER TABLE ls.biz_enrichment
  ADD COLUMN IF NOT EXISTS apps_deep String DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_theme LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_theme_store_id Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS shop_currency LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_locales Nullable(UInt8),
  ADD COLUMN IF NOT EXISTS shopify_plus Nullable(UInt8);

ALTER TABLE ls.biz_enrichment_log
  ADD COLUMN IF NOT EXISTS apps_deep String DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_theme LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_theme_store_id Nullable(UInt32),
  ADD COLUMN IF NOT EXISTS shop_currency LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS shop_locales Nullable(UInt8),
  ADD COLUMN IF NOT EXISTS shopify_plus Nullable(UInt8);

CREATE TABLE IF NOT EXISTS ls.ctl_sightings
(
    `domain`               String,
    `seen_at`              DateTime,
    `ctl_tld`              LowCardinality(String),
    `ctl_issuer`           LowCardinality(String),
    `ctl_subdomain_count`  UInt16,
    `ctl_subdomains`       String
)
ENGINE = MergeTree
ORDER BY (domain, seen_at)
TTL seen_at + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
