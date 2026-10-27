defmodule LS.Schema.Examples do
  @moduledoc """
  Two fictional businesses, one Shopify store and one SaaS, with a value
  for every customer-facing column (2026-10-27). They are the example
  rows on /data, the home page and the features page, and the records
  the docs quote, so a buyer sees what a row holds before paying for one
  and an AI reading the page learns the shape of the data.

  Fictional on purpose: the domains do not resolve and the people do not
  exist, so nothing here can be mistaken for a real company's data or a
  real person's address. The shapes, vocabularies and magnitudes are
  copied from real rows (a Melbourne outdoor store, a London HR SaaS)
  read on the day this shipped, so each value looks the way the live
  value looks. `test/ls/schema_examples_test.exs` holds both records to
  the column dictionary: a column added without an example fails the
  build.
  """

  alias LS.Schema.Columns

  @store %{
    "domain" => "ridgelinecamp.com.au",
    "ctl_first_seen_at" => "2026-09-14 03:12:41",
    "ctl_last_seen_at" => "2026-10-25 02:10:07",
    "http_first_seen_at" => "2026-09-14 05:40:12",
    "http_last_seen_at" => "2026-10-25 02:10:07",
    "http_last_checked_at" => "2026-10-25 02:10:07",
    "http_tech" => ["Shopify", "Klaviyo", "Judge.me", "Shop Pay", "Google Analytics", "Google Tag Manager", "Meta Pixel", "Cloudflare", "Google Fonts", "Open Graph"],
    "http_script_domains" => ["cdn.shopify.com", "static.klaviyo.com", "cdn1.judge.me", "www.googletagmanager.com", "connect.facebook.net"],
    "dns_tech" => ["Klaviyo", "Google Workspace", "Shopify"],
    "dns_email_provider" => "Google Workspace",
    "http_emails" => ["sarah@ridgelinecamp.com.au", "hello@ridgelinecamp.com.au"],
    "http_emails_evidence" => "homepage|contact",
    "http_phone" => "03 9012 4471",
    "http_address" => "14 Harrow Lane, Warrandyte VIC 3113",
    "http_social_links" => ["https://www.instagram.com/ridgelinecamp", "https://www.facebook.com/ridgelinecampco"],
    "http_company_id" => "ABN 61 480 229 117",
    "http_nav_links" => ["Tents", "Sleeping", "Cooking", "Packs", "Sale", "Journal", "Contact"],
    "http_title" => "Ridgeline Camp Co | Camping Gear, Tents and Packs, Shipped Australia-wide",
    "http_meta_description" => "Tents, sleeping bags, stoves and packs chosen by people who camp every weekend. Free shipping over $99, 60-day returns.",
    "http_h1" => "Gear for the next ridge",
    "http_language" => "en",
    "http_schema_type" => "WebSite",
    "http_pages_found" => ["/collections/tents", "/pages/contact", "/pages/about", "/policies/shipping-policy", "/blogs/journal"],
    "http_status" => 200,
    "http_error" => "",
    "http_blocked" => "",
    "http_response_ms" => 412,
    "http_deep_seo_score" => 74,
    "http_deep_seo_issues" => ["meta_description_length", "alt_text_coverage"],
    "http_deep_word_count" => 1180,
    "http_deep_alt_ratio" => 0.61,
    "http_deep_lcp_ms" => 1640,
    "http_deep_cls" => 0.04,
    "http_deep_ttfb_ms" => 290,
    "http_deep_pricing_points" => nil,
    "http_deep_sitemap_urls" => 1532,
    "http_deep_sitemap_products" => 1118,
    "http_deep_sitemap_blog" => 46,
    "http_deep_sitemap_children" => 4,
    "http_deep_sitemap_lastmod" => "2026-10-23 00:00:00",
    "http_deep_last_seen_at" => "2026-10-23 14:02:55",
    "hr_job_count" => 0,
    "hr_ats" => "",
    "hr_departments" => [],
    "hr_locations" => [],
    "hr_last_seen_at" => nil,
    "ctl_has_hiring_subdomain" => 0,
    "shop_product_count" => 1118,
    "shop_new_products_30d" => 37,
    "shop_last_product_at" => "2026-10-22 23:10:04",
    "shop_price_min" => 7.95,
    "shop_price_avg" => 142.6,
    "shop_price_max" => 1299.0,
    "shop_oos_ratio" => 0.12,
    "shop_discount_depth" => 0.18,
    "shop_vendor_count" => 38,
    "shop_catalog_age_days" => 41,
    "shop_product_types" => ["Tents", "Sleeping Bags", "Stoves", "Backpacks", "Headlamps", "Chairs"],
    "shop_theme" => "Impulse",
    "shop_theme_store_id" => 857,
    "shop_currency" => "AUD",
    "shop_locales" => 1,
    "shop_plus" => 0,
    "shop_last_seen_at" => "2026-10-23 14:02:55",
    "dns_a" => ["23.227.38.74"],
    "dns_mx" => ["1:aspmx.l.google.com", "5:alt1.aspmx.l.google.com", "10:alt3.aspmx.l.google.com"],
    "dns_dmarc" => "quarantine",
    "dns_bimi" => "",
    "dns_dkim" => "google",
    "dns_last_seen_at" => "2026-10-25 02:10:07",
    "ctl_tld" => "com.au",
    "ctl_issuer" => "WE1",
    "ctl_subdomain_count" => 3,
    "ctl_subdomains" => ["www", "shop", "track"],
    "rdap_created_at" => "2026-09-12 08:30:00",
    "rdap_expires_at" => "2027-09-12 08:30:00",
    "rdap_updated_at" => "2026-09-12 08:30:00",
    "rdap_registrar" => "VentraIP Australia",
    "rdap_nameservers" => ["dan.ns.cloudflare.com", "lola.ns.cloudflare.com"],
    "rdap_status" => ["client transfer prohibited"],
    "rdap_registrant_country" => "AU",
    "rdap_last_seen_at" => "2026-10-18 06:44:21",
    "bgp_asn" => "13335",
    "bgp_asn_org" => "CLOUDFLARENET - Cloudflare, Inc., US",
    "bgp_country" => "US",
    "bgp_last_seen_at" => "2026-10-25 02:10:07",
    "tranco_rank" => 812_344,
    "majestic_rank" => 964_120,
    "majestic_ref_subnets" => 118,
    "news_count" => nil,
    "news_last_funding_usd" => nil,
    "news_last_seen_at" => nil,
    "estimated_business_model" => "Ecommerce",
    "estimated_business_model_confidence" => 0.99,
    "estimated_business_model_evidence" => "heuristic",
    "estimated_industry" => "Home & Garden",
    "estimated_industry_confidence" => 0.92,
    "estimated_revenue" => "$1M-$10M",
    "estimated_revenue_confidence" => 0.86,
    "estimated_revenue_evidence" => "tranco:top_1m:812344→small|catalog:1118→small|mx:GoogleWorkspace→small|dmarc:p=quarantine→small|sitemap:1532→small",
    "estimated_employees" => "11-50",
    "estimated_employees_confidence" => 0.86,
    "estimated_employees_evidence" => "tranco:top_1m:812344→small|catalog:1118→small|mx:GoogleWorkspace→small|dmarc:p=quarantine→small|sitemap:1532→small",
    "estimated_country" => "AU",
    "estimated_country_evidence" => "company_id:ABN;tld:com.au;lang:en",
    "estimated_country_confidence" => 0.95,
    "estimated_hq_location" => "Warrandyte, Victoria",
    "estimated_hq_location_evidence" => "about page",
    "estimated_summary" => "Online camping gear store for Australian weekend campers: tents, sleeping bags, stoves and packs.",
    "estimated_summary_evidence" => "about page",
    "estimated_junk" => "",
    "estimated_realness" => 0.9,
    "estimated_realness_evidence" => "mx|dmarc|contact|address|company_id|age_90d|activity|traffic|social|catalog",
    "estimated_at" => "2026-10-23 14:30:11",
    "verified_revenue" => "",
    "verified_revenue_evidence" => "",
    "verified_employees" => "",
    "verified_employees_evidence" => "",
    "verified_industry" => "",
    "verified_founded_year" => nil,
    "verified_at" => nil
  }

  @saas %{
    "domain" => "fieldplan.co.uk",
    "ctl_first_seen_at" => "2024-02-19 11:05:33",
    "ctl_last_seen_at" => "2026-10-24 09:51:40",
    "http_first_seen_at" => "2026-06-02 07:14:09",
    "http_last_seen_at" => "2026-10-24 09:51:40",
    "http_last_checked_at" => "2026-10-24 09:51:40",
    "http_tech" => ["Webflow", "HubSpot", "Intercom", "Segment", "Stripe", "Google Tag Manager", "Cloudflare", "Google Fonts", "Open Graph", "reCAPTCHA"],
    "http_script_domains" => ["js.hs-scripts.com", "widget.intercom.io", "cdn.segment.com", "www.googletagmanager.com", "js.stripe.com"],
    "dns_tech" => ["Google Workspace", "HubSpot", "SendGrid", "Postmark"],
    "dns_email_provider" => "Google Workspace",
    "http_emails" => ["tom.ashby@fieldplan.co.uk", "hello@fieldplan.co.uk", "support@fieldplan.co.uk"],
    "http_emails_evidence" => "homepage|contact|about",
    "http_phone" => "+44 20 3920 6611",
    "http_address" => "Unit 4, 22 Clerkenwell Green, London EC1R 0DP",
    "http_social_links" => ["https://www.linkedin.com/company/fieldplan", "https://twitter.com/fieldplanhq"],
    "http_company_id" => "Company number 14477390",
    "http_nav_links" => ["Product", "Pricing", "Customers", "Integrations", "Careers", "Log in"],
    "http_title" => "Fieldplan | Scheduling and job management software for field service teams",
    "http_meta_description" => "Plan jobs, dispatch engineers and invoice from one screen. Built for plumbing, HVAC and electrical firms with 5 to 200 engineers.",
    "http_h1" => "Every engineer in the right place, every morning",
    "http_language" => "en-GB",
    "http_schema_type" => "Organization",
    "http_pages_found" => ["/pricing", "/customers", "/integrations", "/careers", "/about", "/contact", "/blog"],
    "http_status" => 200,
    "http_error" => "",
    "http_blocked" => "",
    "http_response_ms" => 318,
    "http_deep_seo_score" => 82,
    "http_deep_seo_issues" => ["title_length"],
    "http_deep_word_count" => 940,
    "http_deep_alt_ratio" => 0.88,
    "http_deep_lcp_ms" => 1210,
    "http_deep_cls" => 0.02,
    "http_deep_ttfb_ms" => 180,
    "http_deep_pricing_points" => 3,
    "http_deep_sitemap_urls" => 412,
    "http_deep_sitemap_products" => 0,
    "http_deep_sitemap_blog" => 236,
    "http_deep_sitemap_children" => 2,
    "http_deep_sitemap_lastmod" => "2026-10-21 00:00:00",
    "http_deep_last_seen_at" => "2026-10-21 16:20:48",
    "hr_job_count" => 7,
    "hr_ats" => "greenhouse",
    "hr_departments" => ["Engineering", "Sales", "Customer Success"],
    "hr_locations" => ["London", "Remote (UK)"],
    "hr_last_seen_at" => "2026-10-24 09:51:40",
    "ctl_has_hiring_subdomain" => 1,
    "shop_product_count" => nil,
    "shop_new_products_30d" => nil,
    "shop_last_product_at" => nil,
    "shop_price_min" => nil,
    "shop_price_avg" => nil,
    "shop_price_max" => nil,
    "shop_oos_ratio" => nil,
    "shop_discount_depth" => nil,
    "shop_vendor_count" => nil,
    "shop_catalog_age_days" => nil,
    "shop_product_types" => [],
    "shop_theme" => "",
    "shop_theme_store_id" => nil,
    "shop_currency" => "",
    "shop_locales" => nil,
    "shop_plus" => nil,
    "shop_last_seen_at" => nil,
    "dns_a" => ["104.26.4.221", "104.26.5.221"],
    "dns_mx" => ["1:aspmx.l.google.com", "5:alt1.aspmx.l.google.com", "5:alt2.aspmx.l.google.com", "10:alt3.aspmx.l.google.com", "10:alt4.aspmx.l.google.com"],
    "dns_dmarc" => "reject",
    "dns_bimi" => "",
    "dns_dkim" => "google|hs1",
    "dns_last_seen_at" => "2026-10-24 09:51:40",
    "ctl_tld" => "co.uk",
    "ctl_issuer" => "R11",
    "ctl_subdomain_count" => 6,
    "ctl_subdomains" => ["www", "app", "api", "careers", "status", "docs"],
    "rdap_created_at" => "2024-02-12 10:02:17",
    "rdap_expires_at" => "2027-02-12 10:02:17",
    "rdap_updated_at" => "2026-02-05 09:00:00",
    "rdap_registrar" => "Cloudflare, Inc.",
    "rdap_nameservers" => ["aron.ns.cloudflare.com", "pam.ns.cloudflare.com"],
    "rdap_status" => ["client transfer prohibited"],
    "rdap_registrant_country" => "GB",
    "rdap_last_seen_at" => "2026-10-20 03:15:09",
    "bgp_asn" => "13335",
    "bgp_asn_org" => "CLOUDFLARENET - Cloudflare, Inc., US",
    "bgp_country" => "US",
    "bgp_last_seen_at" => "2026-10-24 09:51:40",
    "tranco_rank" => 268_902,
    "majestic_rank" => 391_455,
    "majestic_ref_subnets" => 402,
    "news_count" => 2,
    "news_last_funding_usd" => 2_400_000,
    "news_last_seen_at" => "2026-05-14 08:00:00",
    "estimated_business_model" => "SaaS",
    "estimated_business_model_confidence" => 0.93,
    "estimated_business_model_evidence" => "ml:head_v4_2026-10-19",
    "estimated_industry" => "Productivity",
    "estimated_industry_confidence" => 0.93,
    "estimated_revenue" => "$1M-$10M",
    "estimated_revenue_confidence" => 0.9,
    "estimated_revenue_evidence" => "verified:companies_house→small|tranco:top_500k:268902→small|jobs:7→small|mx:GoogleWorkspace→small|dmarc:p=reject→mid_market",
    "estimated_employees" => "11-50",
    "estimated_employees_confidence" => 0.9,
    "estimated_employees_evidence" => "verified:companies_house→small|tranco:top_500k:268902→small|jobs:7→small|mx:GoogleWorkspace→small|dmarc:p=reject→mid_market",
    "estimated_country" => "GB",
    "estimated_country_evidence" => "company_id:Companies House;schema:GB",
    "estimated_country_confidence" => 0.95,
    "estimated_hq_location" => "London",
    "estimated_hq_location_evidence" => "registry",
    "estimated_summary" => "Scheduling and job-management software for field service firms: dispatch, mobile job sheets and invoicing.",
    "estimated_summary_evidence" => "about page",
    "estimated_junk" => "",
    "estimated_realness" => 0.98,
    "estimated_realness_evidence" => "mx|dmarc|contact|address|company_id|schema_org|age_90d|activity|traffic|social|jobs",
    "estimated_at" => "2026-10-24 10:12:03",
    "verified_revenue" => "$1M-$10M",
    "verified_revenue_evidence" => "Companies House",
    "verified_employees" => "11-50",
    "verified_employees_evidence" => "Companies House",
    "verified_industry" => "62012 Business and domestic software development",
    "verified_founded_year" => 2024,
    "verified_at" => "2026-10-20 03:15:09"
  }

  # The last five recorded changes on each, as /company returns them.
  @store_changes [
    %{field: "http_tech", change: "added", value: "Judge.me", prev_value: "", changed_at: "2026-10-19 02:11:40"},
    %{field: "shop_product_count", change: "changed", value: "1118", prev_value: "903", changed_at: "2026-10-16 23:40:12"},
    %{field: "estimated_revenue", change: "changed", value: "$1M-$10M", prev_value: "<$1M", changed_at: "2026-10-09 14:30:11"},
    %{field: "http_emails", change: "added", value: "sarah@ridgelinecamp.com.au", prev_value: "", changed_at: "2026-10-02 02:05:33"},
    %{field: "http_tech", change: "added", value: "Klaviyo", prev_value: "", changed_at: "2026-09-21 03:17:09"}
  ]

  @saas_changes [
    %{field: "verified_employees", change: "changed", value: "11-50", prev_value: "1-10", changed_at: "2026-10-20 03:15:09"},
    %{field: "hr_job_count", change: "started", value: "7", prev_value: "0", changed_at: "2026-10-12 09:48:02"},
    %{field: "hr_departments", change: "added", value: "Customer Success", prev_value: "", changed_at: "2026-10-12 09:48:02"},
    %{field: "http_tech", change: "added", value: "Intercom", prev_value: "", changed_at: "2026-10-05 10:21:55"},
    %{field: "ctl_subdomains", change: "added", value: "status", prev_value: "", changed_at: "2026-09-28 18:02:40"}
  ]

  @store_contacts %{
    email_details: [
      %{email: "sarah@ridgelinecamp.com.au", kind: "named", source_page: "contact", score: 84, verdict: "strong", evidence: ["published on the contact page", "the domain's mail server answers", "matches the {first} pattern seen on the site"], checked_at: "2026-10-23 14:40:02"},
      %{email: "hello@ridgelinecamp.com.au", kind: "role", source_page: "homepage", score: 71, verdict: "good", evidence: ["published on the homepage", "the domain's mail server answers", "role mailbox"], checked_at: "2026-10-23 14:40:02"}
    ],
    email_pattern: %{pattern: "{first}", support: 1},
    people: [
      %{name: "Sarah Moyle", title: "Founder", email: "sarah@ridgelinecamp.com.au", source_page: "/pages/about", seen_at: "2026-10-23 14:02:55"}
    ]
  }

  @saas_contacts %{
    email_details: [
      %{email: "tom.ashby@fieldplan.co.uk", kind: "named", source_page: "about", score: 88, verdict: "strong", evidence: ["published on the about page", "the domain's mail server answers", "matches the {first}.{last} pattern", "DMARC reject: the domain polices its mail"], checked_at: "2026-10-24 10:20:41"},
      %{email: "hello@fieldplan.co.uk", kind: "role", source_page: "homepage", score: 72, verdict: "good", evidence: ["published on the homepage", "the domain's mail server answers", "role mailbox"], checked_at: "2026-10-24 10:20:41"},
      %{email: "support@fieldplan.co.uk", kind: "role", source_page: "contact", score: 69, verdict: "good", evidence: ["published on the contact page", "the domain's mail server answers", "role mailbox"], checked_at: "2026-10-24 10:20:41"}
    ],
    email_pattern: %{pattern: "{first}.{last}", support: 1},
    people: [
      %{name: "Tom Ashby", title: "Co-founder and CEO", email: "tom.ashby@fieldplan.co.uk", source_page: "/about", seen_at: "2026-10-24 09:51:40"},
      %{name: "Priya Natarajan", title: "Head of Customer Success", email: "", source_page: "/about", seen_at: "2026-10-24 09:51:40"}
    ]
  }

  # Three questions in English and the filters they become. The counts are
  # production numbers read the day this shipped (27 October 2026) and are
  # labelled as such on the page; the rows shown next to them are the
  # fictional examples.
  @queries [
    %{
      id: "stores",
      question: "Find Shopify stores in Australia with 300 or more products that run Klaviyo but not Gorgias, revenue $1M to $10M, with an address on the site.",
      filters: [{"country", "AU"}, {"tech", "Shopify,Klaviyo"}, {"tech_not", "Gorgias"}, {"min_products", "300"}, {"revenue", "$1M-$10M"}, {"has_email", "true"}],
      count: 627,
      example: "store",
      answer: "627 stores match. Here is one, with the fields an app vendor or an agency reads first:"
    },
    %{
      id: "saas",
      question: "Which UK SaaS companies are hiring right now, with a confident label and an address on the site?",
      filters: [{"country", "GB"}, {"business_model", "SaaS"}, {"min_confidence", "0.7"}, {"hiring", "true"}, {"has_email", "true"}],
      count: 77,
      example: "saas",
      answer: "77 companies match. One of them, with the hiring and contact fields:"
    },
    %{
      id: "hiring",
      question: "Who went from zero to open roles in the last 30 days, in the US, UK, Canada or Australia, with an email on the site?",
      filters: [{"changed_field", "hr_job_count"}, {"changed_kind", "started"}, {"changed_within", "30d"}, {"country", "US,GB,CA,AU"}, {"has_email", "true"}],
      count: 1369,
      example: "saas",
      answer: "About 1,400 companies a month. Each row carries the change, its date and the evidence:"
    }
  ]

  @doc "The example questions, their filters and today's counts."
  def queries, do: @queries

  @doc "The dashboard URL that opens a question as a search."
  def dashboard_url(%{filters: filters}), do: "/dashboard?" <> URI.encode_query(filters)

  @doc "The REST call for a question, as a curl line."
  def curl(%{filters: filters}, endpoint \\ "search") do
    "curl \"https://listsignal.com/api/v1/#{endpoint}?#{URI.encode_query(filters)}\" \\\n  -H \"Authorization: Bearer ls_YOUR_KEY\""
  end

  @doc "The MCP tool call for a question, as the JSON an agent sends."
  def mcp(%{filters: filters}, tool \\ "listsignal_count") do
    args = Map.new(filters, fn {k, v} -> {k, mcp_value(v)} end)
    Jason.encode!(%{name: tool, arguments: args}, pretty: true)
  end

  defp mcp_value("true"), do: true

  defp mcp_value(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ ->
        case Float.parse(v) do
          {f, ""} -> f
          _ -> v
        end
    end
  end

  @doc "The fictional Shopify store, every column by name."
  def store, do: @store

  @doc "The fictional SaaS, every column by name."
  def saas, do: @saas

  @doc "Both examples with a label, in the order the pages show them."
  def all, do: [{"store", "Ridgeline Camp Co, a Shopify store in Australia", @store}, {"saas", "Fieldplan, a SaaS in the UK", @saas}]

  def changes("store"), do: @store_changes
  def changes("saas"), do: @saas_changes

  def contacts("store"), do: @store_contacts
  def contacts("saas"), do: @saas_contacts

  @doc "A change as the API prints it, with its one-line summary."
  def change_rows(which) do
    Enum.map(changes(which), fn c ->
      Map.put(c, :summary, LSWeb.ExplorerLive.Format.change_sentence(c.field, c.change, c.value, c.prev_value))
    end)
  end

  @doc """
  The example rendered the way `/api/v1/company` renders a record: every
  API column, then changes, email details, pattern and people.
  """
  def api_record(which) do
    record = if which == "store", do: @store, else: @saas
    contacts = contacts(which)

    Columns.api_columns(:company)
    |> Enum.map(&{&1, Map.get(record, &1)})
    |> Enum.into(%{})
    |> Map.put("changes", change_rows(which))
    |> Map.put("email_details", contacts.email_details)
    |> Map.put("email_pattern", contacts.email_pattern)
    |> Map.put("people", contacts.people)
  end

  @doc "The value of one column on one example, as a short printable string."
  def show(record, name) do
    case Map.get(record, name) do
      nil -> "null"
      "" -> "\"\""
      [] -> "[]"
      list when is_list(list) -> Enum.join(list, ", ")
      v when is_float(v) -> :erlang.float_to_binary(v, decimals: 2) |> String.replace(~r/\.?0+$/, "")
      v -> to_string(v)
    end
  end
end
