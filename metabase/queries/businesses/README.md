# Businesses collection (prod Metabase)

Source of truth for the cards in the prod Metabase "Businesses" collection
(collection 9, dashboard "Businesses 360"), created 2026-07-30 by
`mb_businesses.py` via the API. The ★ EXPORT card is NOT here: it is an MBQL
table card on `ls.v_business_export` (definition in
`clickhouse/views/v_business_export.sql`) so the Metabase filter bar works.
The Browse: biz_* cards are plain MBQL table cards, no SQL.

Iterate in the Metabase editor, then paste back into these files.
