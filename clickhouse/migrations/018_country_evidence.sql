-- ═══════════════════════════════════════════════════════════════════════════
-- 018 — country evidence read off the page, and the RDAP country we already
--       fetch but never kept
--
-- STATUS: apply BEFORE deploying the release that writes these. Additive only,
-- safe on a LIVE app.
--
-- WHY
--   Country attribution feeds every country filter and every list we sell, and
--   it had four signals of which two were weak. Measured 2026-08-27 on 566
--   live generic-TLD sites, scored against evidence the businesses print about
--   themselves (VAT and registration numbers, schema.org addressCountry,
--   dialling prefixes): the rule was correct on 62.8% of the rows it labelled.
--
--   Real customer-visible errors from that: intellatriage.com, a Nashville
--   nurse-triage service, sold as French; eapc-us.com and geteino.com French
--   because they sit on OVH; knowunity.fr French while carrying German VAT
--   DE326705352 on its own site.
--
--   Reordering and widening the hosting-ASN list took it to 76.7% and halved
--   the wrong rows, and that part needs no new data. This migration adds the
--   part that does.
--
-- WHY THE COLUMN IS REQUIRED, NOT OPTIONAL
--   The compactor RECOMPUTES inferred_country on every pass from columns
--   stored in domains_history (LS.Clickhouse, "Recomputed from the surviving
--   signals"). Anything not stored is therefore discarded within minutes.
--   That is exactly what happened to the RDAP registrant country: the crawler
--   fetches it (LS.RDAP.Client.find_registrant_country/1), infer/5 accepts it,
--   and it was never given a column, so sql_expr never saw it and the tier has
--   been dead in `businesses` since it was written. Both columns below exist
--   so evidence survives compaction.
--
-- BACKFILL
--   http_country_evidence fills on recrawl (weekly for digital businesses,
--   monthly for the rest); rows not yet recrawled hold '' and fall through to
--   the ccTLD/RDAP/language/BGP rules exactly as before. The rules half of the
--   change backfills immediately, because compaction recomputes from columns
--   that are already stored.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE ls.domains_history
  ADD COLUMN IF NOT EXISTS http_country_evidence LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS http_country_evidence_src LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS rdap_registrant_country LowCardinality(String) DEFAULT '';

ALTER TABLE ls.businesses
  ADD COLUMN IF NOT EXISTS http_country_evidence LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS http_country_evidence_src LowCardinality(String) DEFAULT '',
  ADD COLUMN IF NOT EXISTS rdap_registrant_country LowCardinality(String) DEFAULT '';
