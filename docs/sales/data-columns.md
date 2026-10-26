# ListSignal data columns

Generated from `LS.Schema.Columns` on 2026-10-26. 121 customer-facing columns, of which **26 are change-tracked**: every change on a tracked column becomes a row in the signal feed (`changes_log`, the `changes` API field, the `listsignal_changes` MCP tool), with the old value, the new value and the date.

Families: **fact** is copied from one public source (prefix names the source). **estimated** is produced by a model or a rule and ships with a confidence. **verified** comes from a registry (Companies House, SIRENE, SEC, Wikidata, YC).

| | |
|---|---|
| 🔔 | change-tracked: a signal is emitted when it moves |
| API | which API surfaces carry it: C = full company record, S = search rows |
| CSV | included in the CSV export |


## Estimates (models and rules, each with a confidence)

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `estimated_business_model` | estimated | 🔔 value changed | CS | yes | What the business is: Ecommerce, SaaS, Agency, Marketplace, Tool, Media, Consulting, LocalBusiness and more. Rules plus a text classifier. |
| `estimated_business_model_confidence` | estimated |  | C | yes | 0 to 1. |
| `estimated_business_model_evidence` | estimated |  | C |  | Which tier decided it: heuristic rules, the ML head, or a government TLD rule. |
| `estimated_industry` | estimated | 🔔 value changed | CS | yes | Industry label from the same classifier. |
| `estimated_industry_confidence` | estimated |  | C |  | 0 to 1. One classifier emits model and industry together today, so it equals the model confidence. |
| `estimated_revenue` | estimated | 🔔 value changed | CS | yes | Annual revenue band: <$1M, $1M-$10M, $10M-$100M, $100M-$1B, $1B+. |
| `estimated_revenue_confidence` | estimated |  | C | yes | 0 to 1, grows with the number of independent signals. |
| `estimated_revenue_evidence` | estimated |  | C | yes | The signals the estimate rests on, pipe-separated, strongest first. |
| `estimated_employees` | estimated | 🔔 value changed | CS | yes | Headcount band: 1-10, 11-50, 51-500, 501-5000, 5001+. |
| `estimated_employees_confidence` | estimated |  | C |  | 0 to 1. Same estimator run as revenue. |
| `estimated_employees_evidence` | estimated |  | C |  | Same evidence trail as revenue. |
| `estimated_country` | estimated | 🔔 value changed | CS | yes | ISO-2 country, from a VAT or registration number on the page, else the registrant country, else TLD, language and hosting. |
| `estimated_country_evidence` | estimated |  | C |  | Which inputs decided the country. |
| `estimated_country_confidence` | estimated |  | C |  | 0.95 from a registration number on the page, 0.85 from the registrant, 0.6 from TLD, language and hosting. |
| `estimated_hq_location` | estimated |  | C | yes | City or address of the head office. |
| `estimated_hq_location_evidence` | estimated |  | C |  | registry or about page. |
| `estimated_summary` | estimated |  | C | yes | One-line description of what the business does. |
| `estimated_summary_evidence` | estimated |  | C |  | registry or about page. |
| `estimated_junk` | estimated | 🔔 value changed | C | yes | Empty when the site looks like a real business; parked or placeholder otherwise. Follows the newest successful fetch. |
| `estimated_realness` | estimated |  | CS | yes | How much evidence says this is an operating business, 0 to 1. 0.5 and up: mail, a contact and 90 days of certificates; 0.7 and up adds traffic, a catalogue or jobs, a registry match or a company number. 0 when junk. |
| `estimated_realness_evidence` | estimated |  | C | yes | The facts behind estimated_realness, '|' separated (mx, dmarc, contact, address, company_id, schema_org, age_90d, activity, traffic, social, registry). |
| `estimated_at` | estimated |  | C |  | When the estimates were last produced. |

## Verified facts (public registries)

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `verified_revenue` | verified | 🔔 value changed | CS | yes | Revenue band from a public registry (SEC EDGAR, Companies House, Wikidata). |
| `verified_revenue_evidence` | verified |  | C | yes | The registry it came from. |
| `verified_employees` | verified | 🔔 value changed | CS | yes | Headcount band from a public registry (Companies House, SIRENE, Wikidata, YC). |
| `verified_employees_evidence` | verified |  | C | yes | The registry it came from. |
| `verified_industry` | verified |  | C |  | Industry as recorded by the registry (NAF, SIC, Wikidata). |
| `verified_founded_year` | verified |  | C | yes | Year of incorporation. |
| `verified_at` | verified |  | C |  | Last registry lookup that returned a fact. |

## What the site says and runs

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `http_first_seen_at` | fact |  |  |  | First successful fetch of the website. |
| `http_last_seen_at` | fact |  | CS | yes | Last successful fetch of the website (HTTP 2xx or 3xx). |
| `http_last_checked_at` | fact |  | C | yes | Last fetch attempt, whatever the outcome. |
| `http_tech` | fact | 🔔 item added or removed | CS | yes | Every technology, platform, plugin and app detected on the website, canonical names from the tech catalog. |
| `http_script_domains` | fact |  | C |  | Third-party hosts the homepage loads scripts from. |
| `http_emails` | fact | 🔔 item added | C | yes | Email addresses published on the site. Paid plans only in the API. |
| `http_emails_evidence` | fact |  | C |  | Which pages the addresses came from. |
| `email_details` (API and MCP get_company) | Each published address with its kind (`named`, `role`, `free_mail`, `sister`) and the page it was found on (`homepage`, `contact`, `legal`, `about`, `career`, `policy`). Since 2026-10-26. |
| `email_pattern` (API and MCP get_company) | The naming shape the named addresses imply (`{first}`, `{first}.{last}`, `{first}{last}`...) with how many addresses support it; null when there is no named address. |
| `people` (API and MCP get_company) | Named people found on the site: name, title, email when published, source page, last seen. From JSON-LD Person, mailto links, imprint lines and team pages. |
| `http_phone` | fact |  | C | yes | Phone number from the footer or JSON-LD. |
| `http_address` | fact |  | C | yes | Postal address from the footer or JSON-LD. |
| `http_social_links` | fact | 🔔 item added | C | yes | Social profile URLs linked from the site. |
| `http_company_id` | fact |  | C | yes | Company registration or VAT number printed on the site, the key into public registries. |
| `http_nav_links` | fact |  | C |  | Main navigation link texts. |
| `http_title` | fact | 🔔 value changed | CS | yes | Homepage title. |
| `http_meta_description` | fact | 🔔 value changed | C | yes | Homepage meta description, usually the tagline. |
| `http_h1` | fact |  | C | yes | Homepage H1. |
| `http_language` | fact |  | CS | yes | Page language, BCP-47. |
| `http_schema_type` | fact |  | C |  | Main schema.org type declared in JSON-LD. |
| `http_pages_found` | fact |  | C |  | Paths discovered on the homepage: /pricing, /about, /careers, /contact. |
| `http_status` | fact | 🔔 went down / came back | C | yes | HTTP status of the last attempt. |
| `http_error` | fact |  | C |  | Fetch error of the last attempt, empty when it succeeded. |
| `http_blocked` | fact |  | C |  | The WAF or bot wall in the way, empty when none is outstanding. |
| `http_response_ms` | fact |  | C | yes | Homepage response time. |

## Shopify store data

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `shop_product_count` | fact | 🔔 moved by 20% or more | CS | yes | Products in the public catalog. |
| `shop_new_products_30d` | fact |  | C | yes | Products added in the last 30 days. |
| `shop_last_product_at` | fact |  | C |  | Newest product's publication date. |
| `shop_price_min` | fact |  | C | yes | Lowest product price. |
| `shop_price_avg` | fact |  | CS | yes | Average product price. |
| `shop_price_max` | fact |  | C | yes | Highest product price. |
| `shop_oos_ratio` | fact |  | C |  | Share of products out of stock. |
| `shop_discount_depth` | fact |  | C |  | Mean markdown against compare-at price. |
| `shop_vendor_count` | fact |  | C | yes | Distinct vendors: 1 is a brand, many is a retailer. |
| `shop_catalog_age_days` | fact |  | C |  | Age of the oldest product. |
| `shop_product_types` | fact |  | C | yes | Product types in the catalog. |
| `shop_theme` | fact | 🔔 value changed | C | yes | Shopify theme name. |
| `shop_theme_store_id` | fact |  | C |  | Theme store id, 0 for a custom theme. |
| `shop_currency` | fact | 🔔 value changed | C | yes | Shop currency. |
| `shop_locales` | fact | 🔔 value changed | C |  | Storefront locales. |
| `shop_plus` | fact | 🔔 value changed | CS | yes | 1 on Shopify Plus. |
| `shop_last_seen_at` | fact |  | C |  | Last successful catalog read. |

## Hiring

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `hr_job_count` | fact | 🔔 started / stopped | CS | yes | Open roles on the public job board. |
| `hr_ats` | fact | 🔔 value changed | C | yes | Applicant tracking system: Greenhouse, Lever, Ashby, Workable and more. |
| `hr_departments` | fact | 🔔 item added | C | yes | Departments with open roles. |
| `hr_locations` | fact |  | C | yes | Locations of open roles, most frequent first. |
| `hr_last_seen_at` | fact |  | C |  | Last successful read of the job board. |

## DNS and email infrastructure

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `dns_tech` | fact | 🔔 item added or removed | CS | yes | Vendors found in DNS: email senders from SPF and DKIM, verification records, CNAME targets. |
| `dns_email_provider` | fact | 🔔 value changed | CS | yes | Who hosts the mailboxes: Google Workspace, Microsoft 365, Zoho, Proton, self-hosted. |
| `dns_a` | fact |  | C |  | IPv4 addresses. |
| `dns_mx` | fact |  | C |  | Mail exchangers. |
| `dns_dmarc` | fact |  | C | yes | DMARC policy: none, quarantine, reject. |
| `dns_bimi` | fact |  | C |  | BIMI logo record. |
| `dns_dkim` | fact |  | C |  | DKIM selectors found. |
| `dns_last_seen_at` | fact |  | C |  | Last crawl where the domain resolved. |

## Certificates (how we discover businesses)

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `ctl_first_seen_at` | fact |  | C | yes | When the domain first appeared in a certificate log. |
| `ctl_last_seen_at` | fact |  |  |  | Last crawl that carried certificate data. |
| `ctl_has_hiring_subdomain` | fact |  | C |  | A careers or jobs host exists in the certificate logs. |
| `ctl_tld` | fact |  | C |  | Top-level domain. |
| `ctl_issuer` | fact |  | C |  | Certificate authority of the newest certificate. |
| `ctl_subdomain_count` | fact |  | C | yes | Distinct hosts seen in certificates. |
| `ctl_subdomains` | fact | 🔔 item added | C |  | Hosts seen in certificates: app, api, shop, careers and the like. |

## Domain registration

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `rdap_created_at` | fact |  | C | yes | Domain registration date. |
| `rdap_expires_at` | fact |  | C |  | Domain expiry date. |
| `rdap_updated_at` | fact |  | C |  | Last registration update. |
| `rdap_registrar` | fact |  | C | yes | Registrar. |
| `rdap_nameservers` | fact |  | C |  | Nameservers. |
| `rdap_status` | fact |  | C |  | EPP status codes. |
| `rdap_registrant_country` | fact |  | C |  | Registrant country when the registry publishes it. |
| `rdap_last_seen_at` | fact |  | C |  | Last registry read. |

## Hosting and network

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `bgp_asn` | fact |  | C |  | Autonomous system number of the hosting network. |
| `bgp_asn_org` | fact |  | C | yes | Hosting network operator: Cloudflare, Amazon, Hetzner and the like. |
| `bgp_country` | fact |  | C |  | Country of the hosting network. |
| `bgp_last_seen_at` | fact |  |  |  | Last crawl with a network lookup. |

## Traffic rank

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `tranco_rank` | fact |  | CS | yes | Tranco traffic rank, lower is bigger. |

## Link authority

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `majestic_rank` | fact |  | C | yes | Majestic Million rank. |
| `majestic_ref_subnets` | fact |  | C |  | Referring subnets, a backlink breadth measure. |

## News and funding

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `news_count` | fact |  | C |  | News items collected. |
| `news_last_funding_usd` | fact | 🔔 value changed | C | yes | Largest funding amount reported. |
| `news_last_seen_at` | fact |  |  |  | Newest news item. |

## Deep crawl

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `http_deep_seo_score` | fact |  | CS | yes | 0 to 100, see /scoring/seo-score. |
| `http_deep_seo_issues` | fact |  | C |  | What the score lost points on. |
| `http_deep_word_count` | fact |  | C |  | Visible words on the homepage. |
| `http_deep_alt_ratio` | fact |  | C |  | Share of images with alt text. |
| `http_deep_lcp_ms` | fact |  | C |  | Largest Contentful Paint, measured in a browser when one was used. |
| `http_deep_cls` | fact |  | C |  | Cumulative Layout Shift. |
| `http_deep_ttfb_ms` | fact |  | C |  | Time to first byte. |
| `http_deep_pricing_points` | fact |  | CS | yes | Count of prices printed on the pricing page. |
| `http_deep_sitemap_urls` | fact |  | C | yes | URLs in the sitemap. |
| `http_deep_sitemap_products` | fact |  | C |  | Product URLs in the sitemap. |
| `http_deep_sitemap_blog` | fact |  | C |  | Blog URLs in the sitemap. |
| `http_deep_sitemap_children` | fact |  |  |  | Child sitemaps. |
| `http_deep_sitemap_lastmod` | fact |  | C |  | Newest lastmod in the sitemap. |
| `http_deep_last_seen_at` | fact |  | C | yes | Last successful deep pass. |

## Other

| Column | Family | 🔔 Signal | API | CSV | What it is |
|---|---|---|---|---|---|
| `domain` | fact |  | CS | yes | The registrable domain, lowercase, no scheme. |
