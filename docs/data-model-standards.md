# Data model standards (decided and built 2026-10-01)

This is the agreed target for the ClickHouse schema, the compactor and the
API, and the record of what was built for it. The code that implements it:
`LS.Schema.Columns` (the product table, one list), `LS.Schema.Tables`,
`LS.Schema.Changes` (changes_log), `LS.Schema.Migration` and
`clickhouse/migrations/025_data_model_v2.sh`, `LS.Tech.Catalog`,
`LS.DNS.Vendors`, `LS.HTTP.PageBlocks`, `LS.Clickhouse.Compact`,
`LS.Signals` and `LSWeb.SignalsLive`. Every number quoted was measured on
production between 2026-09-26 and 2026-10-01.

One decision taken while building, not in the discussion: the enrichment
log (`enrich_log`, `domains`) keeps the worker's internal column names
(`business_model`, `inferred_country`, `http_apps`, pipe-joined strings).
They are the row keys of `LS.Pipeline.merge_row/9` and of the ML feature
builder, and renaming them would have meant touching the classifier, the
estimator and 22 locked test files for no customer-visible gain. The
product table carries the v2 names; the spec's `select` expression is the
bridge from one to the other, and `legacy_alias_ddl/0` keeps the old
product names readable for one release.

## 1. Naming

Columns and tables say where a value comes from. Three families, one rule
each. No other prefix exists.

| Family | Prefix | Meaning | Extra columns |
|---|---|---|---|
| Fact | the producing pipeline: `ctl_`, `dns_`, `http_`, `http_deep_`, `shop_`, `hr_`, `rdap_`, `bgp_`, `news_`, `tranco_`, `majestic_` | copied from one public source, not interpreted | none |
| Estimate | `estimated_` | produced by regex, rules, ML or AI | `_confidence` (Float32 0..1), `_evidence` (String naming the inputs) |
| Verified | `verified_` | confirmed by a registry or a second independent source | `_evidence` (String naming the registry or the check) |

`_source` no longer exists anywhere. The prefix is the source. When the
prefix is not enough (an estimate, a registry fact, a set collected from
several pages) the `_evidence` column says exactly where the value came from.

The website is one source. `http_` covers anything found on the site by any
pass, homepage or deep. `http_deep_` is reserved for metrics that only the
deep pass produces (SEO, performance, sitemap, pricing points). `http_blocked`
is therefore one column, not two.

Timestamps:

- `<pipeline>_last_seen_at`: last successful observation by that pipeline.
- `http_last_checked_at`: last attempt of the enrichment pass, any outcome.
- `http_first_seen_at`, `ctl_first_seen_at`: first success, first discovery.
- `estimated_at`, `verified_at`: when the family was last produced.
- `compiled_at`: version stamp of the compiled row (was `as_of`).

Tables:

- `<pipeline>_log`: append-only observations, one row per sighting, never
  updated, TTL allowed. `ctl_log`, `enrich_log`, `http_deep_log`,
  `verified_log`.
- `changes_log`: derived events, the only table of its kind (section 4).
- `<pipeline>_<things>`: current state, one row per key, ReplacingMergeTree.
  `shop_products`, `shop_collections`, `hr_jobs`, `hr_boards`, `http_pages`.
- `domains` (every domain ever seen) and `businesses` (the product table)
  are the two nouns without prefix.
- `v_` views, `mv_` materialized views, `tmp_` scratch, `bak_` backups.

| Today | Target |
|---|---|
| domains_history | enrich_log |
| domains_current | domains |
| biz_enrichment_log | http_deep_log |
| biz_enrichment | dropped (folded into businesses) |
| biz_products | shop_products |
| biz_collections | shop_collections |
| biz_signal | changes_log |
| ctl_sightings | ctl_log |
| verified_source_records | verified_log |
| verification_domain_keys | verified_keys |
| tech_index | kept, SEO only |
| bak_nxfix_20260730 | dropped |

## 2. The product table, in order of importance

Signal = tracked in `changes_log`. "later" = worth tracking, not in phase 1.

| Field | Today | Target | Type | Signal |
|---|---|---|---|---|
| Domain | domain | domain | String | |
| Business model | business_model | estimated_business_model | LowCardinality | changed |
| Business model confidence | classification_confidence | estimated_business_model_confidence | Float32 | |
| Business model evidence | classification_source | estimated_business_model_evidence | String | |
| Industry | industry | estimated_industry | LowCardinality | changed |
| Industry confidence | | estimated_industry_confidence | Float32 | |
| Revenue band | estimated_revenue | estimated_revenue | LowCardinality | changed |
| Revenue confidence | revenue_confidence | estimated_revenue_confidence | Float32 | |
| Revenue evidence | revenue_evidence | estimated_revenue_evidence | String | |
| Employee band | estimated_employees | estimated_employees | LowCardinality | changed |
| Employee confidence | | estimated_employees_confidence | Float32 | |
| Employee evidence | | estimated_employees_evidence | String | |
| Country | inferred_country | estimated_country | LowCardinality | changed |
| Country confidence | | estimated_country_confidence | Float32 | |
| Country evidence | http_country_evidence, http_country_evidence_src | estimated_country_evidence | String | |
| HQ location | hq_location | estimated_hq_location | String | |
| HQ evidence | | estimated_hq_location_evidence | String | |
| One-line summary | mission, mission_summary | estimated_summary | String | |
| Summary evidence | | estimated_summary_evidence | String | |
| Junk verdict | is_junk | estimated_junk | LowCardinality | changed |
| Estimates produced at | | estimated_at | DateTime | |
| Model version | pipeline_version | estimated_version | LowCardinality | |
| Tech stack and apps | http_tech, http_apps | http_tech | Array(LowCardinality) | added, removed |
| Raw Shopify app handles | | http_shopify_app_handles | Array(String) | |
| Third-party script hosts | http_fingerprint.hosts | http_script_domains | Array(String) | |
| Vendors found in DNS | | dns_tech | Array(LowCardinality) | added, removed |
| Mailbox provider | dns_ms_enterprise | dns_email_provider | LowCardinality | changed |
| Emails | http_emails | http_emails | Array(String) | added |
| Emails evidence | | http_emails_evidence | String | |
| Phone | | http_phone | String | |
| Postal address | | http_address | String | |
| Social profiles | | http_social_links | Array(String) | added |
| Company registration id | | http_company_id | String | |
| Open jobs | job_count | hr_job_count | UInt16 | started, stopped |
| ATS | ats_platform | hr_ats | LowCardinality | changed |
| Departments hiring | job_departments | hr_departments | Array(LowCardinality) | added |
| Hiring locations | job_locations, job_locations_top | hr_locations | Array(String) | added |
| Hiring subdomain | | ctl_has_hiring_subdomain | UInt8 | appeared |
| HR last seen | | hr_last_seen_at | DateTime | |
| Product count | product_count | shop_product_count | UInt32 | crossed 20% |
| New products, 30 days | new_products_30d | shop_new_products_30d | UInt32 | |
| Last product added | last_product_at | shop_last_product_at | DateTime | |
| Price min, avg, max | price_min, price_avg, price_max | shop_price_min, shop_price_avg, shop_price_max | Float32 | |
| Out-of-stock ratio | oos_ratio | shop_oos_ratio | Float32 | |
| Discount depth | discount_depth | shop_discount_depth | Float32 | later |
| Vendor count | vendor_count | shop_vendor_count | UInt32 | |
| Catalog age | catalog_age_days | shop_catalog_age_days | UInt32 | |
| Product types | product_types | shop_product_types | Array(LowCardinality) | |
| Theme | shop_theme | shop_theme | LowCardinality | changed |
| Theme store id | shop_theme_store_id | shop_theme_store_id | UInt32 | |
| Currency | shop_currency | shop_currency | LowCardinality | |
| Locales | shop_locales | shop_locales | UInt8 | |
| Shopify Plus | shopify_plus | shop_plus | UInt8 | changed |
| Shop last seen | | shop_last_seen_at | DateTime | |
| Verified revenue | verified_revenue | verified_revenue | LowCardinality | changed |
| Verified revenue evidence | verified_revenue_source | verified_revenue_evidence | String | |
| Verified employees | verified_employees | verified_employees | LowCardinality | changed |
| Verified employees evidence | verified_employees_source | verified_employees_evidence | String | |
| Legal name | | verified_legal_name | String | |
| Founded | | verified_founded_year | UInt16 | |
| Registry id | | verified_registry_id | String | |
| Verified at | | verified_at | DateTime | |
| Title | http_title | http_title | String | changed |
| Meta description | http_meta_description | http_meta_description | String | changed |
| H1 | http_h1 | http_h1 | String | |
| Language | http_language | http_language | LowCardinality | |
| Schema.org type | http_schema_type | http_schema_type | LowCardinality | |
| Page kinds found | http_pages | http_page_kinds | Array(LowCardinality) | |
| Navigation links | | http_nav_links | Array(String) | |
| HTTP status | http_status, last_http_status | http_status | Int16 | down, back |
| HTTP error | last_http_error | http_error | LowCardinality | |
| Blocked | http_blocked, last_http_blocked | http_blocked | LowCardinality | |
| Crawlable | crawlable | http_crawlable | UInt8 | |
| Response time | http_response_time | http_response_ms | UInt32 | |
| HTTP first seen | | http_first_seen_at | DateTime | |
| HTTP last seen | | http_last_seen_at | DateTime | |
| HTTP last checked | last_verified_at | http_last_checked_at | DateTime | |
| SEO score | seo_score | http_deep_seo_score | UInt8 | |
| SEO issues | seo_issues | http_deep_seo_issues | Array(LowCardinality) | |
| Word count | seo_word_count | http_deep_word_count | UInt32 | |
| Image alt ratio | seo_alt_ratio | http_deep_alt_ratio | Float32 | |
| LCP | perf_lcp_ms | http_deep_lcp_ms | UInt32 | |
| CLS | perf_cls | http_deep_cls | Float32 | |
| TTFB | perf_ttfb_ms | http_deep_ttfb_ms | UInt32 | |
| Render engine | render_engine | http_deep_render_engine | LowCardinality | |
| Pricing points | pricing_points | http_deep_pricing_points | UInt8 | later |
| Sitemap URLs | sitemap_urls | http_deep_sitemap_urls | UInt32 | |
| Sitemap products | sitemap_products | http_deep_sitemap_products | UInt32 | |
| Sitemap blog | sitemap_blog | http_deep_sitemap_blog | UInt32 | |
| Sitemap children | sitemap_children | http_deep_sitemap_children | UInt16 | |
| Sitemap last modified | sitemap_lastmod | http_deep_sitemap_lastmod | DateTime | |
| Sitemap hash | sitemap_hash | http_deep_sitemap_hash | UInt64 | internal |
| Deep pass last seen | depth_enriched_at | http_deep_last_seen_at | DateTime | |
| A records | dns_a | dns_a | Array(String) | |
| MX records | dns_mx | dns_mx | Array(String) | |
| DMARC | dns_dmarc | dns_dmarc | LowCardinality | later |
| BIMI | dns_bimi | dns_bimi | String | |
| DKIM | dns_dkim | dns_dkim | LowCardinality | |
| DNS last seen | dns_alive | dns_last_seen_at | DateTime | |
| TLD | ctl_tld | ctl_tld | LowCardinality | |
| Certificate issuer | ctl_issuer | ctl_issuer | LowCardinality | |
| Subdomain count | ctl_subdomain_count | ctl_subdomain_count | UInt16 | |
| Subdomains | ctl_subdomains | ctl_subdomains | Array(String) | added |
| First discovered | first_seen | ctl_first_seen_at | DateTime | |
| CT last seen | | ctl_last_seen_at | DateTime | |
| Domain created | rdap_domain_created_at | rdap_created_at | DateTime | |
| Domain expires | rdap_domain_expires_at | rdap_expires_at | DateTime | |
| Domain updated | rdap_domain_updated_at | rdap_updated_at | DateTime | |
| Registrar | rdap_registrar | rdap_registrar | LowCardinality | later |
| Nameservers | rdap_nameservers | rdap_nameservers | Array(String) | |
| Domain status | rdap_status | rdap_status | Array(LowCardinality) | |
| Registrant country | rdap_registrant_country | rdap_registrant_country | LowCardinality | |
| RDAP last seen | | rdap_last_seen_at | DateTime | |
| ASN | bgp_asn_number | bgp_asn | UInt32 | |
| ASN organisation | bgp_asn_org | bgp_asn_org | LowCardinality | later |
| ASN country | bgp_asn_country | bgp_country | LowCardinality | |
| Tranco rank | tranco_rank | tranco_rank | UInt32 | |
| Majestic rank | majestic_rank | majestic_rank | UInt32 | |
| Majestic referring subnets | majestic_ref_subnets | majestic_ref_subnets | UInt32 | |
| News mentions | news_count | news_count | UInt16 | |
| Last funding | last_funding_usd | news_last_funding_usd | UInt64 | changed |
| News last seen | | news_last_seen_at | DateTime | |
| Compiled row version | as_of | compiled_at | DateTime | |
| Shopify flag | is_shopify | is_shopify | MATERIALIZED has(http_tech,'Shopify') | internal |
| SaaS flag | is_saas | is_saas | MATERIALIZED | internal |

Dropped from `businesses`, kept in `enrich_log` where they existed: last_worker,
dns_aaaa, dns_txt, dns_cname, dns_ptr, http_content_type, http_og_type,
is_disposable_email, bgp_ip, bgp_asn_prefix, rdap_registrar_iana_id,
positions_overview (now `hr_jobs`), about_text (now `http_pages`),
http_body_snippet (now `http_pages`).

## 3. Page storage: `http_pages`

Key: (domain, page_kind). page_kind in home, about, pricing, contact.
ReplacingMergeTree, latest version only. Text columns CODEC(ZSTD(3)).
Written by the worker that fetched the page. Never read by the compactor.

| Column | Type | Cap |
|---|---|---|
| http_header_tags, http_header_texts | Nested(tag LowCardinality, text String) | 60 blocks, 200 B each |
| http_body_tags, http_body_texts | Nested | 120 blocks, 400 B each |
| http_footer_tags, http_footer_texts | Nested | 60 blocks, 400 B each |
| http_jsonld | String | 16 KB |
| http_fetched_at | DateTime | |

Block tags: h1..h6, p, li, td, dt, dd, blockquote, figcaption. Document
order is preserved by array position. Hidden, aria-hidden, dialog, drawer,
cart and cookie-banner nodes are removed before blocks are emitted. Header
is header/nav/role=banner; footer is footer/role=contentinfo/class footer.

Who gets a page row: http 200, estimated_junk empty, business-model
confidence at least 0.6. 13.4M domains today.

Measured on 394 real homepages loaded into ClickHouse: 2,014 compressed
bytes per page with ZSTD(3), 3,145 with LZ4, against 218,701 bytes of raw
HTML. Body text is 1,086 of those bytes, JSON-LD 328, header 123, footer
119. Homepage for 13.4M domains: 27 GB. Home plus about: about 35 GB. The
500-character snippet it replaces costs 32.6 GiB today across
domains_history and domains_current and holds navigation menus.

What the footer gives, share of pages: footer present 82%, legal links 41%,
social profiles 36%, email 23%, phone 13%, postal address 10%, plus VAT and
company numbers where the law requires them. The current snippet catches an
email on 7%, a phone on 10%, an address on 3%.

What JSON-LD gives: present on 62% of pages. Organization on 40%, with
name, url, logo (155 of 193), sameAs social profiles (84), address (34),
telephone (33), email (22), legalName (15), foundingDate (12). WebSite,
WebPage and BreadcrumbList carry nothing. SoftwareApplication 7%,
LocalBusiness 5%, Product 3%. The worker parses it into http_social_links,
http_phone, http_address, http_company_id and http_schema_type; the raw is
kept for re-parsing.

What og and twitter tags give: og:title equals the title on 233 of 282
pages, og:description equals the meta description on 202 of 258, twitter
tags duplicate og, the generator meta duplicates tech detection. Not stored.

## 4. Signals: `changes_log`

One table. One row per change of one tracked column on one domain.

```
changes_log (
  domain      String,
  field       LowCardinality(String),   -- the businesses column name
  change      LowCardinality(String),   -- added | removed | changed | started | stopped | crossed | down | back
  value       String,                   -- the element added/removed, or the new value
  prev_value  String,
  changed_at  DateTime
) ENGINE = ReplacingMergeTree
ORDER BY (field, value, changed_at, domain)
PROJECTION by_domain (SELECT * ORDER BY domain, changed_at)
```

The tracked columns and their rule are declared once, in the column spec
(section 6), not in a table. Detection runs in the compactor pass, in SQL,
by comparing the new compiled row with the previous compiled row of each
touched domain, which is what biz_signal already does for tech, apps and
jobs with lagInFrame. Containers (Nested blocks, raw JSON-LD) can never be
tracked; a field has to be a scalar or an array column of `businesses`.

Today's biz_signal rows migrate 1:1: tech_added becomes field http_tech,
change added; started_hiring becomes field hr_job_count, change started.

Two rule options on the spec (2026-10-01, after the first morning wrote
15,602 "www added" and 19,399 "social link added" first fills):

- `ignore: [...]`: values that are never a business event. `ctl_subdomains`
  ignores `www`, `mail`, `webmail`, `cpanel`, `autodiscover` and the other
  infrastructure labels (`LS.Schema.Columns.infra_subdomains/0`); `app`,
  `shop`, `api`, `careers` stay, they are the expansion signals.
- `since: "YYYY-MM-DD HH:MM:SS"`: the column could not have been filled
  before this instant, so an old row observed earlier is a first fill, not
  a change. Every column introduced after v2 gets one.

## 5. Compaction rules

Compaction stays in ClickHouse SQL, generated by Elixir from the column
spec. 700k business rows are re-inserted a day, 2,400 per pass, 16 to 26 s
and 1.6 to 1.9 GB per pass. Moving it to the BEAM on a 4 GB master is not
an option.

Every column declares one fold rule:

| Rule | Meaning | Columns |
|---|---|---|
| newest | last observation wins, empty included | http_status, http_error, http_blocked |
| newest_nonempty | last non-empty observation from a fully observed fetch | every scalar fact, http_tech, dns_tech |
| union | union over observations, per-item last seen, items expire after 90 days unseen | ctl_subdomains, http_emails, http_social_links, http_script_domains, http_shopify_app_handles |
| best | highest confidence, deep pass beats homepage | every estimated_ column |

"Fully observed" means the page body was read, not a stub, a block or a
redirect. That guard exists today for http_tech and http_apps only and
extends to every http_ column.

## 6. The column spec

`LS.Schema.Columns` is one Elixir module listing every column of
`businesses` with: name, type, family, fold rule, signal rule, cap, API
visibility, legacy name. It generates the CREATE TABLE, the compactor fold
SQL, the changes_log detection SQL, the API JSON shape, clickhouse/schema.sql
and the column table in this document. A column that is not in the spec
does not exist.

## 7. Tech detection

`tech_detector.ex` stays the closed list it is, about 230 names, with two
new fields per entry: category and ecosystem. `app_detector.ex` keeps its
Shopify extension regex but maps handles through a closed handle-to-name
list of the roughly 350 apps with real footprint; unknown handles go to
http_shopify_app_handles raw. Production today: 288 distinct tech names, 7,304
distinct app values of which 6,262 are one-store handles. Target: about 600
curated names in one array.

The list ships in the release as today. It is also loaded into a small
ClickHouse table so category filters and backfills are SQL, but workers
never read that table.

## 7b. Realness and junk (2026-10-01)

`estimated_junk` follows the newest successful fetch, and a parking
operator's nameservers (`LS.DNS.Parking`, one list for the worker and the
fold) win over whatever the parking page looks like. Hosting defaults that
sound like parking (Hostinger's dns-parking.com, 731K real businesses) are
deliberately not on the list.

`estimated_realness` (0 to 1) with `estimated_realness_evidence` is the
answer to "real businesses only": weighted facts already in the row (MX,
DMARC, a contact, an address, a company number, a business schema.org
type, 90 days of certificates, a catalogue or jobs, traffic, social links,
a registry match), zero for junk. `LS.Schema.Realness` generates the SQL
for the fold, the v1 transform and the backfill from one list. Weights are
a first cut to be scored against the golden set before anything gates on
them; the evidence string is what makes that scoring possible. The
dashboard filters on a band (0.7+, 0.5+, 0.3+), the API on `min_realness`.

Three internal capture columns, stored at fetch time and folded as the
newest observed value: `http_etag` and `http_last_modified` (the validators
a conditional GET will send back, phase two), `http_body_simhash` (64-bit
simhash of the visible text, `LS.HTTP.Simhash`, for template clustering).

## 8. Fetching

Which resolved domains get an HTTP fetch is `LS.HTTP.DomainFilter.verdict/4`
(see architecture.md, "Dormant and hot rings"). A filtered domain writes no
row; its verdict is remembered by the crawl gate.

The rate limiter keys by destination IP with a 1,000 ms spacing. Shopify's
1.4M stores sit behind a handful of edge addresses (23.227.38.x), so every
node hits each address once a second in parallel and Shopify sees one
client: 3.6% of Shopify fetches end in 429 against 0.37% fleet-wide, and
82,309 stores hold a 429 as their last result. Fix: key by destination /24
or ASN for shared edges (Shopify, Cloudflare, Wix, Squarespace), retry 429
from a different node after a delay. Camoufox stays for WAF walls, 401,
403, 503; it does not fix an IP rate limit.

## 9. Migration plan

Additive first, rename last, nothing big-bang.

1. Back up: `/home/ls/backup.sh all`.
2. Ship the column spec, the page extractor, the closed app map and the
   limiter fix to workers. Workers write new columns alongside old ones
   (ALTER ADD COLUMN is 0.056 s). `http_pages` starts filling as the
   recrawl ring passes, about 34 days to cover the 13.4M.
3. Backfill by SQL what is derivable: arrays from pipe strings,
   dns_email_provider and dns_tech from stored dns_mx and dns_txt,
   estimated_ renames, verified_ evidence from the _source columns,
   changes_log from biz_signal.
4. Switch the compactor to the spec-generated fold with the four rules.
5. Switch readers: explorer, API, /trends, alerts, DataCheck, Metabase
   queries (22 files), api_data.ex.
6. Rename tables and columns. Keep the old column names for one release
   as ALIAS columns so nothing breaks in between, then drop them along with
   the snippet columns and bak_nxfix_20260730.
7. Regenerate clickhouse/schema.sql, update architecture.md, log entry.

Open items before step 1: 22 committed test files reference old column
names and are locked; the owner has to create `.claude/tests-unlock` for
the renaming window. Disk is 361 GB with 123 GB free; pages need 27 to 35
GB and the backup grows with them. The about-page fetch (About.analyze
reading html_of(visited, :about)) and the re-score of estimates when the
deep pass lands are part of step 2.
