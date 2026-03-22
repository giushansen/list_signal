-- Migration v4: Clean tech detection
-- Drop http_tools (was always producing garbage), add http_apps

ALTER TABLE ls.enrichments ADD COLUMN IF NOT EXISTS http_apps String DEFAULT '' AFTER http_is_js_site;
ALTER TABLE ls.enrichments DROP COLUMN IF EXISTS http_tools;
