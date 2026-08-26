-- ═══════════════════════════════════════════════════════════════════════════
-- 016 — contact provenance: on_domain flag + per-page fetch telemetry
--
-- STATUS: apply BEFORE deploying the release that writes these. New column +
-- new table only, so it is safe on a LIVE app; the writer logs an insert error
-- every batch until they exist.
--
-- WHY (1) biz_contact.on_domain
--   Imprint pages are legally required to name a contact, and they routinely
--   name someone ELSE'S: the agency that built the site, the host, and German
--   statutory arbitration boards (schlichtungsstelle@s-d-r.org is boilerplate).
--   Measured 2026-08-26 on German business domains: 40.6% of them yield an
--   address from a second page, but only 28.1% yield one on the business's own
--   domain. Selling the other 12.5% as "this company's email" is simply wrong.
--
--   Flag, do not filter. Dropping the rows would destroy a real signal — the
--   agency relationship is itself sellable, and an off-domain address is often
--   the only reachable human at a tiny business. Consumers that need "this
--   business's own mailbox" filter on on_domain = 1.
--
-- WHY (2) biz_page_fetch
--   Enrichment.Agent.fetch_page/3 collapsed every failure into
--   %{html: nil, source: "failed"} — no status, no error, nothing stored. So
--   "how often does a contact-page fetch actually work?" could only be answered
--   by re-crawling a sample by hand, which is how the redirect bug below was
--   found at all. One row per attempted page fetch makes it a query.
--
--   That probe (300 domains, real client) measured: homepage 95.7% OK,
--   secondary pages 76.2%, and 68% of the failures came from ONE bug — the
--   redirect follower re-sent the original path, so /contact -> /contact/
--   looped until it ran out of hops. Fixed in the same release. This table is
--   how we would have seen it without a probe, and how we will see the next one.
--
-- Sparse columns compress ~191:1 on this cluster, so the cost is noise.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE ls.biz_contact
  ADD COLUMN IF NOT EXISTS on_domain UInt8 DEFAULT 0;

CREATE TABLE IF NOT EXISTS ls.biz_page_fetch
(
    `domain`      String,
    `page_kind`   LowCardinality(String),  -- home | contact | legal | about | pricing | career
    `path`        String,
    `outcome`     LowCardinality(String),  -- ok | http_error | rate_limited | redirect_loop | timeout | error | thin
    `status`      Int32 DEFAULT 0,         -- HTTP status when we got one, else 0
    `elapsed_ms`  UInt32 DEFAULT 0,
    `seen_at`     DateTime
)
ENGINE = MergeTree
ORDER BY (domain, seen_at, page_kind)
TTL seen_at + INTERVAL 90 DAY
SETTINGS index_granularity = 8192
;
