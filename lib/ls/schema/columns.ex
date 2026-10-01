defmodule LS.Schema.Columns do
  @moduledoc """
  The `businesses` product table, declared once (data model v2, 2026-10-01).

  Every column of the product table is one entry below with its name, its
  ClickHouse type, where its value comes from in the compactor fold, how it
  maps from the v1 table for the one-time migration, which legacy name it
  keeps as an ALIAS for one release, whether a change on it is a signal,
  and which API surfaces show it. From this one list the code derives:

    * the CREATE TABLE (`ddl/0`) and the legacy ALIAS columns (`legacy_alias_ddl/0`);
    * the compactor's INSERT list and SELECT list (`insert_columns/0`, `fold_select/0`);
    * the v1 -> v2 transform (`v1_select/0`);
    * the `changes_log` detection rules (`tracked/0`);
    * the API JSON shape (`api_columns/1`) and the CSV export (`export_columns/0`);
    * the data dictionary on the developers page (`doc_rows/0`).

  A column that is not in this list does not exist. The rules are the
  owner's, from `docs/data-model-standards.md`:

    * prefix = producing pipeline (`ctl_` `dns_` `http_` `http_deep_` `shop_`
      `hr_` `rdap_` `bgp_` `news_` `tranco_` `majestic_`) for a fact copied
      from one public source;
    * `estimated_` for anything a rule or a model produced, with
      `_confidence` and `_evidence`;
    * `verified_` for a registry fact, with `_evidence` naming the registry;
    * `_source` does not exist; `<pipeline>_last_seen_at` is the last
      successful observation by that pipeline.

  The enrichment log keeps the worker's internal column names (they are the
  row keys of `LS.Pipeline.merge_row/9` and of the ML feature builder); the
  `select` expression of each entry is the bridge from those names to the
  product name. `h`, `s`, `v`, `p`, `n`, `c`, `ct` are the fold's join
  aliases: history, deep pass, verified facts, pricing, news, certificate
  sightings, contacts (see `LS.Clickhouse.compact_sql/3`).
  """

  @type rule :: :set | :set_added | :changed | :started_stopped | :down_back | {:pct, float()}

  @type t :: %{
          name: String.t(),
          type: String.t(),
          default: String.t() | nil,
          legacy: String.t() | nil,
          select: String.t(),
          v1: String.t(),
          family: :fact | :estimated | :verified | :internal,
          signal: rule() | nil,
          api: [:company | :search],
          export: boolean(),
          internal: boolean(),
          doc: String.t()
        }

  # ── helpers used inside the list ────────────────────────────────────────

  @tech_list "arrayConcat(splitByChar('|', h.http_tech), splitByChar('|', h.http_apps), splitByChar('|', ifNull(s.apps_deep, '')))"

  # Names pass through the alias map (humanised Shopify handles such as
  # "Judgeme" become "Judge.me"), then only catalog names survive. Both
  # scalars come from the fold's WITH clause (`LS.Clickhouse.catalog_with/0`).
  defp catalog_filter(list_sql),
    do:
      "arrayDistinct(arrayFilter(x -> x != '' AND has(_catalog, x), arrayMap(x -> transform(x, _alias_from, _alias_to, x), #{list_sql})))"

  defp split(col), do: "arrayFilter(x -> x != '', splitByChar('|', #{col}))"
  defp split_nullable(col), do: "arrayFilter(x -> x != '', splitByChar('|', ifNull(#{col}, '')))"

  # The verified facts plausibility guard, unchanged from v1 (2026-09-06/07):
  # a Tranco top-1K site cannot be under $100M or 500 people, a top-10K
  # site cannot be under $10M or 50 people. A fact that contradicts observed
  # traffic is a wrong entity, not a fact.
  @rev_implausible "((h.tranco_rank <= 1000 AND v.verified_revenue NOT IN ('$100M-$1B', '$1B+')) OR (h.tranco_rank <= 10000 AND v.verified_revenue IN ('<$1M', '$1M-$10M')))"
  @emp_implausible "((h.tranco_rank <= 1000 AND v.verified_employees NOT IN ('501-5000', '5001+')) OR (h.tranco_rank <= 10000 AND v.verified_employees IN ('1-10', '11-50')))"

  @deep_est "ifNull(s.d_est_revenue, '') != ''"

  defp c(name, type, opts) do
    %{
      name: name,
      type: type,
      default: Keyword.get(opts, :default),
      legacy: Keyword.get(opts, :legacy),
      select: Keyword.fetch!(opts, :select),
      v1: Keyword.get(opts, :v1, Keyword.get(opts, :legacy) && "b.#{Keyword.get(opts, :legacy)}") || "b.#{name}",
      family: Keyword.get(opts, :family, :fact),
      signal: Keyword.get(opts, :signal),
      # since: the column could not have been filled before this instant, so an
      # old row observed earlier is a first fill, not a change (2026-10-01:
      # 19,399 "social link added" rows on the first v2 morning were exactly that).
      since: Keyword.get(opts, :since),
      # ignore: values that are infrastructure, never a business event.
      ignore: Keyword.get(opts, :ignore, []),
      api: Keyword.get(opts, :api, []),
      export: Keyword.get(opts, :export, false),
      internal: Keyword.get(opts, :internal, false),
      doc: Keyword.get(opts, :doc, "")
    }
  end

  # Subdomain labels a certificate carries for mail, hosting panels and
  # device enrolment. 2026-10-01, first v2 passes: www alone was 15,602 of
  # 54,219 subdomain events, the labels below together about half of them.
  # app., shop., api., careers. stay: those are the expansion signals.
  @infra_subdomains ~w(www mail webmail webdisk cpanel cpcalendars cpcontacts autodiscover autoconfig
                       m smtp mta-sts email imap pop pop3 ftp ns ns1 ns2 ns3 mx mx1 mx2 localhost whm
                       server host vpn remote owa exchange _dmarc _domainkey sip lyncdiscover
                       enterpriseregistration enterpriseenrollment msoid wildcard * cdn static assets
                       img images mailserver secure www2 ww1 ipv4 ipv6 relay bounce newsletter mta)

  @doc "Subdomain labels the change feed ignores."
  def infra_subdomains, do: @infra_subdomains

  @v2_at "2026-10-01 08:25:00"

  defp build do
    [
    # ── identity and time ───────────────────────────────────────────────
    c("domain", "String", select: "h.domain", api: [:company, :search], export: true, doc: "The registrable domain, lowercase, no scheme."),
    c("compiled_at", "DateTime", legacy: "as_of", select: "h.as_of", internal: true, doc: "Version stamp of the compiled row (newest crawl of any kind)."),
    c("ctl_first_seen_at", "DateTime", legacy: "first_seen", select: "h.first_seen", api: [:company], export: true, doc: "When the domain first appeared in a certificate log."),
    c("ctl_last_seen_at", "Nullable(DateTime)", select: "h.ctl_last_seen_at", v1: "b.as_of", doc: "Last crawl that carried certificate data."),
    c("http_first_seen_at", "Nullable(DateTime)", select: "h.http_first_seen_at", v1: "b.last_verified_at", doc: "First successful fetch of the website."),
    c("http_last_seen_at", "Nullable(DateTime)", legacy: "last_verified_at", select: "h.last_verified_at", api: [:company, :search], export: true, doc: "Last successful fetch of the website (HTTP 2xx or 3xx)."),
    c("http_last_checked_at", "DateTime", select: "h.as_of", v1: "b.as_of", api: [:company], export: true, doc: "Last fetch attempt, whatever the outcome."),

    # ── estimates ───────────────────────────────────────────────────────
    c("estimated_business_model", "LowCardinality(String)", default: "''", legacy: "business_model", select: "h.business_model", family: :estimated, signal: :changed, api: [:company, :search], export: true, doc: "What the business is: Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting, LocalBusiness and more. Rules plus a text classifier."),
    c("estimated_business_model_confidence", "Nullable(Float32)", legacy: "classification_confidence", select: "h.classification_confidence", family: :estimated, api: [:company], export: true, doc: "0 to 1."),
    c("estimated_business_model_evidence", "String", default: "''", legacy: "classification_source", select: "h.classification_source", family: :estimated, api: [:company], doc: "Which tier decided it: heuristic rules, the ML head, or a government TLD rule."),
    c("estimated_industry", "LowCardinality(String)", default: "''", legacy: "industry", select: "h.industry", family: :estimated, signal: :changed, api: [:company, :search], export: true, doc: "Industry label from the same classifier."),
    c("estimated_industry_confidence", "Nullable(Float32)", select: "h.classification_confidence", v1: "b.classification_confidence", family: :estimated, api: [:company], doc: "0 to 1. One classifier emits model and industry together today, so it equals the model confidence."),
    c("estimated_revenue", "LowCardinality(String)", default: "''", legacy: "estimated_revenue", select: "if(#{@deep_est}, s.d_est_revenue, h.estimated_revenue)", family: :estimated, signal: :changed, api: [:company, :search], export: true, doc: "Annual revenue band: <$1M, $1M-$10M, $10M-$100M, $100M-$1B, $1B+."),
    c("estimated_revenue_confidence", "Nullable(Float32)", legacy: "revenue_confidence", select: "if(#{@deep_est}, s.d_rev_confidence, h.revenue_confidence)", family: :estimated, api: [:company], export: true, doc: "0 to 1, grows with the number of independent signals."),
    c("estimated_revenue_evidence", "String", default: "''", legacy: "revenue_evidence", select: "if(#{@deep_est}, s.d_rev_evidence, h.revenue_evidence)", family: :estimated, api: [:company], export: true, doc: "The signals the estimate rests on, pipe-separated, strongest first."),
    c("estimated_employees", "LowCardinality(String)", default: "''", legacy: "estimated_employees", select: "if(#{@deep_est}, s.d_est_employees, h.estimated_employees)", family: :estimated, signal: :changed, api: [:company, :search], export: true, doc: "Headcount band: 1-10, 11-50, 51-500, 501-5000, 5001+."),
    c("estimated_employees_confidence", "Nullable(Float32)", select: "if(#{@deep_est}, s.d_rev_confidence, h.revenue_confidence)", v1: "b.revenue_confidence", family: :estimated, api: [:company], doc: "0 to 1. Same estimator run as revenue."),
    c("estimated_employees_evidence", "String", default: "''", select: "if(#{@deep_est}, s.d_rev_evidence, h.revenue_evidence)", v1: "b.revenue_evidence", family: :estimated, api: [:company], doc: "Same evidence trail as revenue."),
    c("estimated_country", "LowCardinality(String)", default: "''", legacy: "inferred_country", select: :country, family: :estimated, signal: :changed, api: [:company, :search], export: true, doc: "ISO-2 country, from a VAT or registration number on the page, else the registrant country, else TLD, language and hosting."),
    c("estimated_country_evidence", "String", default: "''", select: "if(h.http_country_evidence != '', concat(h.http_country_evidence_src, ':', h.http_country_evidence), if(h.rdap_registrant_country != '', concat('rdap:', h.rdap_registrant_country), concat('tld:', h.ctl_tld, ';lang:', h.http_language, ';asn:', h.bgp_asn_country)))", v1: "if(b.http_country_evidence != '', concat(b.http_country_evidence_src, ':', b.http_country_evidence), if(b.rdap_registrant_country != '', concat('rdap:', b.rdap_registrant_country), concat('tld:', b.ctl_tld, ';lang:', b.http_language, ';asn:', b.bgp_asn_country)))", family: :estimated, api: [:company], doc: "Which inputs decided the country."),
    c("estimated_country_confidence", "Nullable(Float32)", select: "multiIf(h.http_country_evidence != '', 0.95, h.rdap_registrant_country != '', 0.85, h.inferred_country != '', 0.6, NULL)", v1: "multiIf(b.http_country_evidence != '', 0.95, b.rdap_registrant_country != '', 0.85, b.inferred_country != '', 0.6, NULL)", family: :estimated, api: [:company], doc: "0.95 from a registration number on the page, 0.85 from the registrant, 0.6 from TLD, language and hosting."),
    c("estimated_hq_location", "String", default: "''", legacy: "hq_location", select: "if(ifNull(v.hq, '') != '', v.hq, ifNull(s.hq_location, ''))", v1: "b.hq_location", family: :estimated, api: [:company], export: true, doc: "City or address of the head office."),
    c("estimated_hq_location_evidence", "String", default: "''", select: "multiIf(ifNull(v.hq, '') != '', 'registry', ifNull(s.hq_location, '') != '', 'about page', '')", v1: "if(b.hq_location != '', 'about page', '')", family: :estimated, api: [:company], doc: "registry or about page."),
    c("estimated_summary", "String", default: "''", select: "if(ifNull(v.mission_summary, '') != '', v.mission_summary, ifNull(s.mission, ''))", v1: "if(b.mission_summary != '', b.mission_summary, b.mission)", family: :estimated, api: [:company], export: true, doc: "One-line description of what the business does."),
    c("estimated_summary_evidence", "String", default: "''", select: "multiIf(ifNull(v.mission_summary, '') != '', 'registry', ifNull(s.mission, '') != '', 'about page', '')", v1: "multiIf(b.mission_summary != '', 'registry', b.mission != '', 'about page', '')", family: :estimated, api: [:company], doc: "registry or about page."),
    c("estimated_junk", "LowCardinality(String)", default: "''", legacy: "is_junk", select: :junk, family: :estimated, signal: :changed, api: [:company], export: true, doc: "Empty when the site looks like a real business; parked or placeholder otherwise. Follows the newest successful fetch."),
    c("estimated_realness", "Float32", default: "0", select: :realness, v1: :realness_v1, family: :estimated, api: [:company, :search], export: true, doc: "How much evidence says this is an operating business, 0 to 1: mail setup, a contact, a company number, schema.org, 90 days of certificates, a catalogue or jobs, traffic, social links, a registry match. 0 when junk."),
    c("estimated_realness_evidence", "String", default: "''", select: :realness_evidence, v1: :realness_evidence_v1, family: :estimated, api: [:company], export: true, doc: "The facts behind estimated_realness, '|' separated (mx, dmarc, contact, address, company_id, schema_org, age_90d, activity, traffic, social, registry)."),
    c("estimated_at", "Nullable(DateTime)", select: "if(#{@deep_est}, s.enriched_at_newest, h.as_of)", v1: "if(b.depth_enriched_at IS NOT NULL, b.depth_enriched_at, b.as_of)", family: :estimated, api: [:company], doc: "When the estimates were last produced."),
    c("estimated_version", "LowCardinality(String)", default: "''", legacy: "pipeline_version", select: "h.pipeline_version", family: :estimated, internal: true, doc: "Build that produced the estimates."),

    # ── technology ──────────────────────────────────────────────────────
    c("http_tech", "Array(LowCardinality(String))", select: :tech, v1: :tech_v1, signal: :set, api: [:company, :search], export: true, doc: "Every technology, platform, plugin and app detected on the website, canonical names from the tech catalog."),
    c("http_apps", "String", default: "''", select: :apps_legacy, v1: :apps_legacy_v1, internal: true, doc: "Legacy: the ecosystem add-ons from http_tech as a pipe string, for readers not yet on the array. Dropped next release."),
    c("http_shopify_app_handles", "Array(String)", select: split("h.http_shopify_app_handles"), v1: "[]", internal: true, doc: "Raw Shopify theme-extension handles before the catalog map, so a new catalog entry backfills by SQL."),
    c("http_script_domains", "Array(String)", select: "JSONExtract(h.http_fingerprint, 'hosts', 'Array(String)')", v1: "[]", api: [:company], doc: "Third-party hosts the homepage loads scripts from."),
    c("dns_tech", "Array(LowCardinality(String))", select: :dns_tech, v1: :dns_tech_v1, signal: :set, api: [:company, :search], export: true, doc: "Vendors found in DNS: email senders from SPF and DKIM, verification records, CNAME targets."),
    c("dns_email_provider", "LowCardinality(String)", default: "''", legacy: "dns_ms_enterprise", select: :dns_email_provider, v1: :dns_email_provider_v1, signal: :changed, api: [:company, :search], export: true, doc: "Who hosts the mailboxes: Google Workspace, Microsoft 365, Zoho, Proton, self-hosted."),

    # ── contact ─────────────────────────────────────────────────────────
    c("http_emails", "Array(String)", select: "arraySlice(arrayDistinct(arrayFilter(x -> x != '', arrayConcat(h.http_emails_all, ifNull(ct.emails, [])))), 1, 20)", v1: "arraySlice(arrayDistinct(arrayFilter(x -> x != '', splitByChar('|', b.http_emails))), 1, 20)", signal: :set_added, api: [:company], export: true, doc: "Email addresses published on the site. Paid plans only in the API."),
    c("http_emails_evidence", "String", default: "''", select: "arrayStringConcat(arrayDistinct(arrayConcat(if(h.http_emails != '', ['homepage'], []), ifNull(ct.pages, []))), '|')", v1: "if(b.http_emails != '', 'homepage', '')", api: [:company], doc: "Which pages the addresses came from."),
    c("http_phone", "String", default: "''", select: "h.http_phone", v1: "''", api: [:company], export: true, doc: "Phone number from the footer or JSON-LD."),
    c("http_address", "String", default: "''", select: "h.http_address", v1: "''", api: [:company], export: true, doc: "Postal address from the footer or JSON-LD."),
    c("http_social_links", "Array(String)", select: "arraySlice(h.http_social_links, 1, 20)", v1: "[]", signal: :set_added, since: @v2_at, api: [:company], export: true, doc: "Social profile URLs linked from the site."),
    c("http_etag", "String", default: "''", select: "h.http_etag", v1: "''", internal: true, doc: "ETag the homepage last answered with; sent back as If-None-Match so an unchanged page costs a 304, not a body."),
    c("http_last_modified", "String", default: "''", select: "h.http_last_modified", v1: "''", internal: true, doc: "Last-Modified the homepage last answered with (If-Modified-Since on the next check)."),
    c("http_body_simhash", "UInt64", default: "0", select: "h.http_body_simhash", v1: "0", internal: true, doc: "64-bit simhash of the visible text; near-identical values across many domains mark a template, not a business."),
    c("http_company_id", "String", default: "''", select: "h.http_company_id", v1: "''", api: [:company], export: true, doc: "Company registration or VAT number printed on the site, the key into public registries."),
    c("http_nav_links", "Array(String)", select: "arraySlice(h.http_nav_links_arr, 1, 60)", v1: "[]", api: [:company], doc: "Main navigation link texts."),

    # ── website ─────────────────────────────────────────────────────────
    c("http_title", "String", default: "''", select: "h.http_title", signal: :changed, api: [:company, :search], export: true, doc: "Homepage title."),
    c("http_meta_description", "String", default: "''", select: "h.http_meta_description", signal: :changed, api: [:company], export: true, doc: "Homepage meta description, usually the tagline."),
    c("http_h1", "String", default: "''", select: "h.http_h1", api: [:company], export: true, doc: "Homepage H1."),
    c("http_language", "LowCardinality(String)", default: "''", select: "h.http_language", api: [:company, :search], export: true, doc: "Page language, BCP-47."),
    c("http_schema_type", "LowCardinality(String)", default: "''", select: "h.http_schema_type", api: [:company], doc: "Main schema.org type declared in JSON-LD."),
    c("http_pages_found", "Array(String)", legacy: "http_pages", select: split("h.http_pages"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.http_pages))", api: [:company], doc: "Paths discovered on the homepage: /pricing, /about, /careers, /contact."),
    c("http_status", "Nullable(Int32)", legacy: "last_http_status", select: "h.last_http_status", signal: :down_back, api: [:company], export: true, doc: "HTTP status of the last attempt."),
    c("http_error", "LowCardinality(String)", default: "''", legacy: "last_http_error", select: "h.last_http_error", api: [:company], doc: "Fetch error of the last attempt, empty when it succeeded."),
    c("http_blocked", "LowCardinality(String)", default: "''", legacy: "last_http_blocked", select: "h.last_http_blocked", api: [:company], doc: "The WAF or bot wall in the way, empty when none is outstanding."),
    c("http_crawlable", "Nullable(UInt8)", legacy: "crawlable", select: "h.crawlable", internal: true, doc: "1 when any fetch ever reached the site."),
    c("http_response_ms", "Nullable(Int32)", legacy: "http_response_time", select: "h.http_response_time", api: [:company], export: true, doc: "Homepage response time."),

    # ── deep pass ───────────────────────────────────────────────────────
    c("http_deep_seo_score", "Nullable(UInt8)", legacy: "seo_score", select: "s.seo_score", api: [:company, :search], export: true, doc: "0 to 100, see /scoring/seo-score."),
    c("http_deep_seo_issues", "Array(LowCardinality(String))", legacy: "seo_issues", select: split_nullable("s.seo_issues"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.seo_issues))", api: [:company], doc: "What the score lost points on."),
    c("http_deep_word_count", "Nullable(UInt32)", legacy: "seo_word_count", select: "s.seo_word_count", api: [:company], doc: "Visible words on the homepage."),
    c("http_deep_alt_ratio", "Nullable(Float32)", legacy: "seo_alt_ratio", select: "s.seo_alt_ratio", api: [:company], doc: "Share of images with alt text."),
    c("http_deep_lcp_ms", "Nullable(UInt32)", legacy: "perf_lcp_ms", select: "s.perf_lcp_ms", api: [:company], doc: "Largest Contentful Paint, measured in a browser when one was used."),
    c("http_deep_cls", "Nullable(Float32)", legacy: "perf_cls", select: "s.perf_cls", api: [:company], doc: "Cumulative Layout Shift."),
    c("http_deep_ttfb_ms", "Nullable(UInt32)", legacy: "perf_ttfb_ms", select: "s.perf_ttfb_ms", api: [:company], doc: "Time to first byte."),
    c("http_deep_render_engine", "LowCardinality(String)", default: "''", legacy: "render_engine", select: "ifNull(s.render_engine, '')", internal: true, doc: "http or camoufox: how the deep pass read the site."),
    c("http_deep_pricing_points", "Nullable(UInt8)", legacy: "pricing_points", select: "p.pricing_points", api: [:company, :search], export: true, doc: "Count of prices printed on the pricing page."),
    c("http_deep_sitemap_urls", "Nullable(UInt32)", legacy: "sitemap_urls", select: "s.sitemap_urls", api: [:company], export: true, doc: "URLs in the sitemap."),
    c("http_deep_sitemap_products", "Nullable(UInt32)", legacy: "sitemap_products", select: "s.sitemap_products", api: [:company], doc: "Product URLs in the sitemap."),
    c("http_deep_sitemap_blog", "Nullable(UInt32)", legacy: "sitemap_blog", select: "s.sitemap_blog", api: [:company], doc: "Blog URLs in the sitemap."),
    c("http_deep_sitemap_children", "Nullable(UInt16)", legacy: "sitemap_children", select: "s.sitemap_children", doc: "Child sitemaps."),
    c("http_deep_sitemap_lastmod", "Nullable(DateTime)", legacy: "sitemap_lastmod", select: "s.sitemap_lastmod", api: [:company], doc: "Newest lastmod in the sitemap."),
    c("http_deep_sitemap_hash", "Nullable(UInt64)", legacy: "sitemap_hash", select: "s.sitemap_hash", internal: true, doc: "Change detection."),
    c("http_deep_last_seen_at", "Nullable(DateTime)", legacy: "depth_enriched_at", select: "s.enriched_at_newest", api: [:company], export: true, doc: "Last successful deep pass."),

    # ── hiring ──────────────────────────────────────────────────────────
    c("hr_job_count", "Nullable(UInt16)", legacy: "job_count", select: "s.job_count", signal: :started_stopped, api: [:company, :search], export: true, doc: "Open roles on the public job board."),
    c("hr_ats", "LowCardinality(String)", default: "''", legacy: "ats_platform", select: "ifNull(s.ats_platform, '')", signal: :changed, api: [:company], export: true, doc: "Applicant tracking system: Greenhouse, Lever, Ashby, Workable and more."),
    c("hr_departments", "Array(LowCardinality(String))", legacy: "job_departments", select: split_nullable("s.job_departments"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.job_departments))", signal: :set_added, api: [:company], export: true, doc: "Departments with open roles."),
    c("hr_locations", "Array(String)", legacy: "job_locations", select: split_nullable("s.job_locations"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.job_locations))", api: [:company], export: true, doc: "Locations of open roles, most frequent first."),
    c("hr_last_seen_at", "Nullable(DateTime)", select: "s.hr_at", v1: "if(b.job_count IS NOT NULL, b.depth_enriched_at, NULL)", api: [:company], doc: "Last successful read of the job board."),
    c("ctl_has_hiring_subdomain", "UInt8", select: "arrayExists(x -> x IN ('careers', 'jobs', 'career', 'hiring', 'recruiting', 'talent', 'join', 'apply'), ctl_subdomains)", v1: "arrayExists(x -> x IN ('careers', 'jobs', 'career', 'hiring', 'recruiting', 'talent', 'join', 'apply'), splitByChar('|', b.ctl_subdomains))", api: [:company], doc: "A careers or jobs host exists in the certificate logs."),

    # ── shop ────────────────────────────────────────────────────────────
    c("shop_product_count", "Nullable(UInt32)", legacy: "product_count", select: "s.product_count", signal: {:pct, 0.2}, api: [:company, :search], export: true, doc: "Products in the public catalog."),
    c("shop_new_products_30d", "Nullable(UInt32)", legacy: "new_products_30d", select: "s.new_products_30d", api: [:company], export: true, doc: "Products added in the last 30 days."),
    c("shop_last_product_at", "Nullable(DateTime)", legacy: "last_product_at", select: "s.last_product_at", api: [:company], doc: "Newest product's publication date."),
    c("shop_price_min", "Nullable(Float32)", legacy: "price_min", select: "s.price_min", api: [:company], export: true, doc: "Lowest product price."),
    c("shop_price_avg", "Nullable(Float32)", legacy: "price_avg", select: "s.price_avg", api: [:company, :search], export: true, doc: "Average product price."),
    c("shop_price_max", "Nullable(Float32)", legacy: "price_max", select: "s.price_max", api: [:company], export: true, doc: "Highest product price."),
    c("shop_oos_ratio", "Nullable(Float32)", legacy: "oos_ratio", select: "s.oos_ratio", api: [:company], doc: "Share of products out of stock."),
    c("shop_discount_depth", "Nullable(Float32)", legacy: "discount_depth", select: "s.discount_depth", api: [:company], doc: "Mean markdown against compare-at price."),
    c("shop_vendor_count", "Nullable(UInt32)", legacy: "vendor_count", select: "s.vendor_count", api: [:company], export: true, doc: "Distinct vendors: 1 is a brand, many is a retailer."),
    c("shop_catalog_age_days", "Nullable(UInt32)", legacy: "catalog_age_days", select: "s.catalog_age_days", api: [:company], doc: "Age of the oldest product."),
    c("shop_product_types", "Array(LowCardinality(String))", legacy: "product_types", select: split_nullable("s.product_types"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.product_types))", api: [:company], export: true, doc: "Product types in the catalog."),
    c("shop_theme", "LowCardinality(String)", default: "''", select: "ifNull(s.shop_theme, '')", signal: :changed, api: [:company], export: true, doc: "Shopify theme name."),
    c("shop_theme_store_id", "Nullable(UInt32)", select: "s.shop_theme_store_id", api: [:company], doc: "Theme store id, 0 for a custom theme."),
    c("shop_currency", "LowCardinality(String)", default: "''", select: "ifNull(s.shop_currency, '')", signal: :changed, api: [:company], export: true, doc: "Shop currency."),
    c("shop_locales", "Nullable(UInt8)", select: "s.shop_locales", signal: :changed, api: [:company], doc: "Storefront locales."),
    c("shop_plus", "Nullable(UInt8)", legacy: "shopify_plus", select: "s.shopify_plus", signal: :changed, api: [:company, :search], export: true, doc: "1 on Shopify Plus."),
    c("shop_last_seen_at", "Nullable(DateTime)", select: "s.shop_at", v1: "if(b.product_count IS NOT NULL, b.depth_enriched_at, NULL)", api: [:company], doc: "Last successful catalog read."),

    # ── verified (registries) ───────────────────────────────────────────
    c("verified_revenue", "LowCardinality(String)", default: "''", select: "if(#{@rev_implausible}, '', v.verified_revenue)", family: :verified, signal: :changed, api: [:company, :search], export: true, doc: "Revenue band from a public registry (SEC EDGAR, Companies House, Wikidata)."),
    c("verified_revenue_evidence", "String", default: "''", legacy: "verified_revenue_source", select: "if(#{@rev_implausible}, '', v.verified_revenue_source)", family: :verified, api: [:company], export: true, doc: "The registry it came from."),
    c("verified_employees", "LowCardinality(String)", default: "''", select: "if(#{@emp_implausible}, '', v.verified_employees)", family: :verified, signal: :changed, api: [:company, :search], export: true, doc: "Headcount band from a public registry (Companies House, SIRENE, Wikidata, YC)."),
    c("verified_employees_evidence", "String", default: "''", legacy: "verified_employees_source", select: "if(#{@emp_implausible}, '', v.verified_employees_source)", family: :verified, api: [:company], export: true, doc: "The registry it came from."),
    c("verified_industry", "String", default: "''", select: "ifNull(v.industry, '')", v1: "''", family: :verified, api: [:company], doc: "Industry as recorded by the registry (NAF, SIC, Wikidata)."),
    c("verified_founded_year", "Nullable(UInt16)", select: "v.founded_year", v1: "NULL", family: :verified, api: [:company], export: true, doc: "Year of incorporation."),
    c("verified_at", "Nullable(DateTime)", select: "v.verified_at", v1: "NULL", family: :verified, api: [:company], doc: "Last registry lookup that returned a fact."),

    # ── dns ─────────────────────────────────────────────────────────────
    c("dns_a", "Array(String)", select: split("h.dns_a"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.dns_a))", api: [:company], doc: "IPv4 addresses."),
    c("dns_mx", "Array(String)", select: split("h.dns_mx"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.dns_mx))", api: [:company], doc: "Mail exchangers."),
    c("dns_dmarc", "LowCardinality(String)", default: "''", select: "h.dns_dmarc", api: [:company], export: true, doc: "DMARC policy: none, quarantine, reject."),
    c("dns_bimi", "String", default: "''", select: "h.dns_bimi", api: [:company], doc: "BIMI logo record."),
    c("dns_dkim", "LowCardinality(String)", default: "''", select: "h.dns_dkim", api: [:company], doc: "DKIM selectors found."),
    c("dns_last_seen_at", "Nullable(DateTime)", select: "h.dns_last_seen_at", v1: "if(b.dns_alive = 1, b.as_of, NULL)", api: [:company], doc: "Last crawl where the domain resolved."),

    # ── certificates ────────────────────────────────────────────────────
    c("ctl_tld", "LowCardinality(String)", default: "''", select: "h.ctl_tld", api: [:company], doc: "Top-level domain."),
    c("ctl_issuer", "LowCardinality(String)", default: "''", select: "h.ctl_issuer", api: [:company], doc: "Certificate authority of the newest certificate."),
    c("ctl_subdomain_count", "Nullable(Int32)", select: "length(ctl_subdomains)", v1: "b.ctl_subdomain_count", api: [:company], export: true, doc: "Distinct hosts seen in certificates."),
    c("ctl_subdomains", "Array(String)", select: "arraySlice(arrayDistinct(arrayConcat(h._subs_hist, ifNull(c.subs, []))), 1, 300)", v1: "arrayFilter(x -> x != '', splitByChar('|', b.ctl_subdomains))", signal: :set_added, ignore: @infra_subdomains, api: [:company], doc: "Hosts seen in certificates: app, api, shop, careers and the like."),

    # ── registration ────────────────────────────────────────────────────
    c("rdap_created_at", "Nullable(DateTime)", legacy: "rdap_domain_created_at", select: "h.rdap_domain_created_at", api: [:company], export: true, doc: "Domain registration date."),
    c("rdap_expires_at", "Nullable(DateTime)", legacy: "rdap_domain_expires_at", select: "h.rdap_domain_expires_at", api: [:company], doc: "Domain expiry date."),
    c("rdap_updated_at", "Nullable(DateTime)", legacy: "rdap_domain_updated_at", select: "h.rdap_domain_updated_at", api: [:company], doc: "Last registration update."),
    c("rdap_registrar", "LowCardinality(String)", default: "''", select: "h.rdap_registrar", api: [:company], export: true, doc: "Registrar."),
    c("rdap_nameservers", "Array(String)", select: split("h.rdap_nameservers"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.rdap_nameservers))", api: [:company], doc: "Nameservers."),
    c("rdap_status", "Array(LowCardinality(String))", select: split("h.rdap_status"), v1: "arrayFilter(x -> x != '', splitByChar('|', b.rdap_status))", api: [:company], doc: "EPP status codes."),
    c("rdap_registrant_country", "LowCardinality(String)", default: "''", select: "h.rdap_registrant_country", api: [:company], doc: "Registrant country when the registry publishes it."),
    c("rdap_last_seen_at", "Nullable(DateTime)", select: "h.rdap_last_seen_at", v1: "if(b.rdap_registrar != '', b.as_of, NULL)", api: [:company], doc: "Last registry read."),

    # ── network ─────────────────────────────────────────────────────────
    c("bgp_asn", "LowCardinality(String)", default: "''", legacy: "bgp_asn_number", select: "h.bgp_asn_number", api: [:company], doc: "Autonomous system number of the hosting network."),
    c("bgp_asn_org", "LowCardinality(String)", default: "''", select: "h.bgp_asn_org", api: [:company], export: true, doc: "Hosting network operator: Cloudflare, Amazon, Hetzner and the like."),
    c("bgp_country", "LowCardinality(String)", default: "''", legacy: "bgp_asn_country", select: "h.bgp_asn_country", api: [:company], doc: "Country of the hosting network."),
    c("bgp_last_seen_at", "Nullable(DateTime)", select: "h.bgp_last_seen_at", v1: "if(b.bgp_asn_number != '', b.as_of, NULL)", doc: "Last crawl with a network lookup."),

    # ── rank ────────────────────────────────────────────────────────────
    c("tranco_rank", "Nullable(Int32)", select: "h.tranco_rank", api: [:company, :search], export: true, doc: "Tranco traffic rank, lower is bigger."),
    c("majestic_rank", "Nullable(Int32)", select: "h.majestic_rank", api: [:company], export: true, doc: "Majestic Million rank."),
    c("majestic_ref_subnets", "Nullable(Int32)", select: "h.majestic_ref_subnets", api: [:company], doc: "Referring subnets, a backlink breadth measure."),

    # ── news ────────────────────────────────────────────────────────────
    c("news_count", "Nullable(UInt16)", select: "n.news_count", api: [:company], doc: "News items collected."),
    c("news_last_funding_usd", "Nullable(UInt64)", legacy: "last_funding_usd", select: "n.last_funding_usd", signal: :changed, api: [:company], export: true, doc: "Largest funding amount reported."),
    c("news_last_seen_at", "Nullable(DateTime)", select: "n.last_at", v1: "NULL", doc: "Newest news item.")
    ]
  end

  @materialized [
    {"is_shopify", "UInt8", "has(http_tech, 'Shopify')"},
    {"is_saas", "UInt8", "estimated_business_model = 'SaaS'"}
  ]

  # Legacy names that are not plain renames of one column, kept as ALIAS
  # expressions for one release so unmigrated readers keep working.
  @legacy_expr_aliases [
    {"mission", "String", "estimated_summary"},
    {"mission_summary", "String", "estimated_summary"},
    {"dns_alive", "UInt8", "toUInt8(notEmpty(dns_a))"},
    {"http_country_evidence", "String", "estimated_country_evidence"},
    {"bgp_ip", "String", "arrayElement(dns_a, 1)"}
  ]

  @doc "Every product column, in table order."
  @spec all() :: [t()]
  def all, do: build()

  def names, do: Enum.map(all(), & &1.name)

  @doc "The column, or nil."
  def get(name), do: Enum.find(all(), &(&1.name == name))

  @doc "Columns the compactor writes (every declared column; MATERIALIZED flags are computed by the table)."
  def insert_columns, do: names()

  @doc "Columns a change on which is recorded in changes_log, with the rule."
  def tracked, do: for(%{signal: r} = col <- all(), r != nil, do: {col.name, r, col.type})

  @doc "Tracked columns with their rule options (`since`, `ignore`), as the detector consumes them."
  def tracked_rules,
    do: for(%{signal: r} = col <- all(), r != nil, do: {col.name, r, col.type, [since: col.since, ignore: col.ignore]})

  @doc "Columns shown by the given API surface, in order."
  def api_columns(surface) when surface in [:company, :search],
    do: for(col <- all(), surface in col.api, do: col.name)

  @doc "Columns a CSV export carries, in order."
  def export_columns, do: for(col <- all(), col.export, do: col.name)

  @doc "Customer-facing columns for the data dictionary (nothing internal)."
  def doc_rows, do: for(col <- all(), not col.internal, do: {col.name, col.type, col.family, col.signal, col.doc})

  @doc "`legacy name -> new name` for every plain rename."
  def legacy_map, do: for(%{legacy: l} = col <- all(), l != nil and l != col.name, into: %{}, do: {l, col.name})

  def array?(%{type: "Array(" <> _}), do: true
  def array?(_), do: false

  # ── SQL generation ───────────────────────────────────────────────────────

  @doc """
  The fold's SELECT list: `expr AS name` per column, in insert order. The
  three symbolic entries resolve here so the SQL for tech, DNS vendors and
  country lives next to the code that owns those rules.
  """
  def fold_select do
    Enum.map_join(all(), ",\n      ", fn col -> "#{fold_expr(col)} AS #{col.name}" end)
  end

  def fold_expr(%{select: :tech}), do: catalog_filter(@tech_list)

  def fold_expr(%{select: :apps_legacy}),
    do: "arrayStringConcat(arrayFilter(x -> has(_apps_catalog, x), #{catalog_filter(@tech_list)}), '|')"

  # Junk follows the newest successful fetch, and a parking nameserver wins
  # over whatever page the parker served (2026-10-01: 132K businesses sat on
  # Sedo, Bodis, Dovendi and friends with an empty junk flag, 64K of them
  # with "tech" detected on the parking page).
  def fold_expr(%{select: :junk}),
    do: "if(#{LS.DNS.Parking.sql("splitByChar('|', h.rdap_nameservers)")}, 'parked', h.is_junk)"

  # The realness score reads other columns' fold expressions, never their
  # aliases, so the same SQL runs in the fold, the v1 transform and a
  # backfill over businesses (LS.Schema.Realness).
  def fold_expr(%{select: :realness}), do: LS.Schema.Realness.score_sql(&fold_expr(get(&1)))
  def fold_expr(%{select: :realness_evidence}), do: LS.Schema.Realness.evidence_sql(&fold_expr(get(&1)))

  def fold_expr(%{select: :dns_tech}), do: LS.DNS.Vendors.tech_sql("h.dns_mx", "h.dns_txt", "h.dns_cname")
  def fold_expr(%{select: :dns_email_provider}), do: LS.DNS.Vendors.email_provider_sql("h.dns_mx")

  def fold_expr(%{select: :country}),
    do:
      LS.CountryInferrer.sql_expr(
        "h.ctl_tld",
        "h.http_language",
        "h.bgp_asn_country",
        "h.bgp_asn_org",
        "h.http_country_evidence",
        "h.rdap_registrant_country"
      )

  def fold_expr(%{select: sql}) when is_binary(sql), do: sql

  @doc "The v1 -> v2 transform, `expr AS name` per column, reading the old table as `b`."
  def v1_select do
    Enum.map_join(all(), ",\n      ", fn col -> "#{v1_expr(col)} AS #{col.name}" end)
  end

  def v1_expr(%{v1: :tech_v1}), do: catalog_filter("arrayConcat(splitByChar('|', b.http_tech), splitByChar('|', b.http_apps))")

  def v1_expr(%{v1: :apps_legacy_v1}),
    do:
      "arrayStringConcat(arrayFilter(x -> has(_apps_catalog, x), #{catalog_filter("arrayConcat(splitByChar('|', b.http_tech), splitByChar('|', b.http_apps))")}), '|')"

  def v1_expr(%{v1: :realness_v1}), do: LS.Schema.Realness.score_sql(&v1_expr(get(&1)))
  def v1_expr(%{v1: :realness_evidence_v1}), do: LS.Schema.Realness.evidence_sql(&v1_expr(get(&1)))

  def v1_expr(%{v1: :dns_tech_v1}), do: LS.DNS.Vendors.tech_sql("b.dns_mx", "b.dns_txt", "b.dns_cname")
  def v1_expr(%{v1: :dns_email_provider_v1}), do: LS.DNS.Vendors.email_provider_sql("b.dns_mx")
  def v1_expr(%{v1: sql}) when is_binary(sql), do: sql

  @doc "CREATE TABLE for the product table."
  def ddl(table \\ "businesses") do
    cols =
      Enum.map_join(all(), ",\n  ", fn col ->
        "`#{col.name}` #{col.type}#{if col.default, do: " DEFAULT #{col.default}", else: ""}"
      end)

    mats = Enum.map_join(@materialized, ",\n  ", fn {n, t, e} -> "`#{n}` #{t} MATERIALIZED #{e}" end)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      #{cols},
      #{mats},
      INDEX idx_shop_product_count shop_product_count TYPE minmax GRANULARITY 4,
      INDEX idx_hr_job_count hr_job_count TYPE minmax GRANULARITY 4,
      INDEX idx_http_deep_seo_score http_deep_seo_score TYPE minmax GRANULARITY 4,
      INDEX idx_http_tech http_tech TYPE bloom_filter(0.01) GRANULARITY 4
    ) ENGINE = ReplacingMergeTree(compiled_at)
    ORDER BY domain
    SETTINGS index_granularity = 8192
    """
  end

  @doc """
  ALTER statements adding every legacy name as an ALIAS of its new column,
  one release of compatibility for readers not yet migrated (Metabase, SEO
  pages). Arrays get no alias: a reader of a pipe string has to change.
  """
  def legacy_alias_ddl(table \\ "businesses") do
    renames =
      for %{legacy: l} = col <- all(), l != nil and l != col.name, not array?(col) do
        "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS `#{l}` #{col.type} ALIAS #{col.name}"
      end

    exprs =
      for {name, type, expr} <- @legacy_expr_aliases do
        "ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS `#{name}` #{type} ALIAS #{expr}"
      end

    renames ++ exprs
  end
end
