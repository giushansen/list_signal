# ListSignal data fact sheet

Numbers read from the production database on 18 October 2026. Paste this
into the claude.ai project so Claude knows what the data is, and is not,
before it recommends anything. Refresh it monthly (`docs/sales/README.md`
has the queries).

## What ListSignal is

A crawler that watches every new TLS certificate in the world, visits the
website behind it, reads the page, and keeps watching. It turns that into
one row per business with what the business is, what it runs, how big it
probably is, how to reach it, and what changed since last time. Nothing
is bought in; every value comes from our own crawl, which is why there is
no per-row cost and why coverage is wide and depth is uneven.

## How much

| | Count |
|---|---|
| Businesses tracked (not junk) | 25.8M |
| With a business-model label | 20.8M |
| Fetched successfully in the last 90 days | 22.2M |
| With at least one email address found on the site | 10.6M (41%) |
| With a phone number found on the site | 988K (3.8%) |
| With social profile links | 2.0M |
| With an estimated revenue band | 24.6M (estimated, see accuracy) |
| With revenue verified from a public filing or registry | 19.8K |
| Currently hiring (open roles seen on their own careers page) | 49.8K |
| Shopify stores | 1.72M |
| Stores with product catalogues read (count, prices, vendors) | 629K stores, 81.8M products |
| Job postings on file | 918K postings across 53K companies |
| Change events recorded (all time) | 9.9M |
| New businesses added | about 210K a day |

## Where (businesses with a country)

| Country | Businesses | With an email |
|---|---|---|
| US | 2.47M | 1.15M |
| DE | 1.81M | 665K |
| FR | 1.54M | 673K |
| GB | 1.39M | 657K |
| BR | 933K | 423K |
| NL | 889K | 453K |
| JP | 835K | 101K |
| IT | 634K | 362K |
| ES | 585K | 311K |
| AU | 571K | 247K |
| CA | 463K | 206K |
| CH | 369K | 188K |

Country is inferred from the site, the TLD and the mail setup; 16.1M of
25.8M businesses have one.

## What kind of business (labels in the product)

| Business model | Businesses | Label precision (measured, golden v6) |
|---|---|---|
| Ecommerce | 8.4M | 77% (inflated by an old WooCommerce rule; being corrected, falls daily) |
| LocalBusiness (clinics, trades, restaurants, venues) | 2.5M | 92% |
| Consulting | 2.1M | 100% on a small sample |
| Agency (marketing, web, SEO, recruiting, lead gen) | 1.7M | 80% |
| SaaS | 1.5M | 73 to 78% |
| Education | 852K | 75% |
| Media | 836K | 100% on a small sample |
| Community | 753K | not measured, weak |
| Manufacturer | 576K | 75% on a small sample |
| Tool (free utilities, calculators, single-purpose apps) | 502K | 57% |
| Nonprofit | 430K | not measured |
| Marketplace | 354K | weak, do not sell as a segment |
| Directory, Newsletter | 269K, 251K | weak |

Industries (top): Construction & Manufacturing 826K, Healthcare 811K,
Productivity 797K, Ecommerce & Retail 764K, Fashion 751K, Marketing 725K,
Home & Garden 624K, DevTools 611K, Education 543K, Media 477K, Food &
Beverage 433K, Travel 412K, Real Estate 399K, Beauty 362K, Legal 358K.
Industry is less accurate than the business model; treat it as a hint.

Agency niches, by what their homepage says (confidence 0.7 or better):
SEO/PPC 51K, web design and development 39K, recruiting 9K, ecommerce
growth 8K, lead generation 5K, email/lifecycle (Klaviyo) 3.6K, Shopify
agencies 2.4K. SaaS selling to ecommerce: 7.7K.

## How big (estimates)

Employees: 1-10 18.7M, 11-50 4.4M, 51-500 825K, 501-5000 587K, 5001+ 11K.
Revenue: under $1M 18.7M, $1M-$10M 4.6M, $10M-$100M 718K, $100M-$1B 569K,
$1B+ 2.5K.

These are estimates from infrastructure and page signals (hosting, mail
setup, registrar, domain age, catalogue size, hiring, traffic rank).
Measured against hand-verified truth: the exact band is right 73% of the
time and within one band 96% of the time. The $100M-$1B band is still
over-used on older rows and is being corrected.

## What they run (technologies seen on the site)

WordPress 9.6M, Cloudflare 7.0M, Google Analytics 5.0M, WooCommerce 4.7M,
Google Workspace 3.7M, Elementor 3.4M, Yoast SEO 3.2M, Microsoft 365
3.2M, Google Tag Manager 3.2M, Contact Form 7 2.8M, Shopify 1.7M, Meta
Pixel 1.4M, plus about 500 other technologies, plugins and apps (HubSpot,
Klaviyo, Webflow, Wix, Squarespace, Framer, Stripe, Intercom, and so on).

## What changes (the signals, last 30 days)

| Signal | Volume |
|---|---|
| New Shopify stores first seen | 364K |
| Technology added to a site | 1.64M |
| Technology removed | 1.14M |
| Email found on a site for the first time | 507K |
| Revenue band changed | 141K |
| Employee band changed | 143K |
| Business model changed | 80K |
| Site went down | 15K |
| Site came back | 5.6K |
| Hiring started | 12.7K |
| Hiring stopped | 1.9K |
| Shopify theme changed | 6.9K |
| Store currency changed | 3.4K |
| Store catalogue size changed | 2.8K |

Every change carries the domain, the field, the direction, the old and
new value and the time. The signals page in the dashboard filters on all
of them; the API has `/api/v1/changes`; MCP has `listsignal_changes`.

## What we do not have

- People. No names, titles, LinkedIn profiles or personal emails. The
  email on a row is what the website publishes, usually info@, contact@,
  hello@ or a named address when the site shows one. Buyers enrich the
  person with Apollo, Clay or similar; so does every competitor at this
  price.
- Phone numbers for most rows (3.8%).
- Verified financials, except the 19.8K rows with a public filing.
- Ad spend, web traffic volumes, funding rounds (a funding field exists
  and is empty), social follower counts.
- Anything about a business with no website.
- Perfect labels. The numbers above are measured; quote them as "about".

## How a customer gets it

- Dashboard: explorer with filters (technology, country, business model,
  industry, revenue and employee band, hiring, Shopify, has email, has
  pricing, catalogue), saved presets, CSV export; a signals page with the
  change feed and its own export.
- API: `/api/v1/company/:domain`, `/search`, `/technologies`, `/changes`,
  `/stats`. Free key 1,000 calls a month at 30 a minute, Starter 5,000 at
  60 a minute, Pro 25,000 at 120 a minute. Contact emails and phone on
  paid plans only.
- MCP: `https://listsignal.com/mcp` with a Bearer key, or
  `https://listsignal.com/mcp/k/ls_KEY` for clients that cannot send
  headers (claude.ai custom connectors). Four tools: get company, search
  companies, changes, dataset stats.
- Plans on the site: Free (searches, no email, no CSV), Starter $39 a
  month, Pro $149 a month, a custom list for $499. The outbound plan
  prices a handpicked weekly feed at $149, $349 and $799 a month and
  one-off lists at $99, $249 and $499.

## Comparables customers will name

StoreLeads: $75 browse-only, $250 for export and API, 13.7M stores,
app install history, no people either. BuiltWith: from $295 a month,
technology data across the web, no change feed at this price.
StoreCensus: from $199, ecommerce only. ListSignal is cheaper, covers
all businesses not only stores, and sells the change, which they do not.
