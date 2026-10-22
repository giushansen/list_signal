# Technology detection: the open fingerprint base, our own mining, and what it bought (2026-10-22)

## Question

The published technology list (`LS.Tech.Catalog`, 505 names) was grown by
hand: every few months a session reads the web, decides what a technology
means, and edits the rules in `LS.HTTP.TechDetector` (about 230 of them).
Is there an open, self-hostable source that does this better, and does the
gain justify an automated process?

## Sources compared

1. **webappanalyzer** (github.com/enthec/webappanalyzer), the community
   continuation of the Wappalyzer fingerprints after Wappalyzer closed its
   data in 2023. 7,647 technologies, 109 categories, GPL-3. Per technology
   it carries script hosts, meta tags, headers, cookies, DNS records, HTML
   regexes, JavaScript globals and DOM queries, plus `implies` relations
   and a SaaS/open-source flag. The GPL covers the data file; a service we
   run ourselves is not a distribution, so using it in the crawler is fine,
   and the file is kept as data under `priv/tech/`, not merged into the code.
2. **Our own crawl.** We do not store page HTML at scale, so script hosts
   could only be mined from the 616 cached golden homepages (v6 + v7). DNS,
   which we do store for 26M domains, was mined at scale: TXT verification
   prefixes, CNAME targets and MX hosts over a 2M-row week of `enrich_log`.

`compare_webappanalyzer.py` runs the fingerprints against the cached pages
and against our detector's output on the same pages; `build_fingerprints.py`
writes `priv/tech/fingerprints.json` from a curated name list.

## What the comparison said (616 pages)

| | our detector | webappanalyzer (script, html, meta only) |
|---|---|---|
| technologies per page | 2.9 | 4.5 |
| distinct names on these pages | 112 | 281 |

Of the 281 names it found, 192 are not in our catalog, but the top of that
list is noise: MySQL (implied from WordPress), jQuery Migrate, OWL
Carousel, imagesLoaded, Magnific Popup, Modernizr, Popper, WordPress Block
Editor. 171 of our 505 names have no counterpart there, because of naming
(Google Fonts vs Google Font API, Meta Pixel vs Facebook Pixel) and because
our Shopify-app and WordPress-plugin names are finer than its categories.
It also misses vendors our 616 pages carry: Trustindex, TrustedSite, Umami,
CallRail, Leadoo, Unbxd, CCM19, CleanTalk, Hostinger Reach.

## What was merged

- **Fingerprint layer** (`LS.HTTP.Fingerprints`, `priv/tech/fingerprints.json`):
  275 vendors, 325 patterns. A curated list of about 890 business-relevant
  names was matched by exact normalised name against the open base; 722
  matched; names we already publish were skipped (our rules stay); names
  with only JavaScript, DOM or DNS evidence were dropped (no rendered page);
  infrastructure categories (CDNs, JavaScript libraries, web servers) were
  dropped as buyer-irrelevant; patterns shorter than six literal characters
  without a dot, slash or dash were dropped. One false positive found in
  review was removed: "Website Builder" in a meta generator, which Wix writes.
  Nine vendors come from our own script-host mining. 184 of the 275 are SaaS.
- **Catalog**: 505 to 780 names, one line per fingerprinted vendor.
- **DNS vendor tokens** (`LS.DNS.Vendors`): 14 more verification prefixes,
  with their weekly counts in a 2M-row sample: Zoho 40K, GlobalSign 32K,
  Proton Mail 11K, KnowBe4 5.5K, Sophos 4.0K, LinkedIn 3.7K, Slack 3.0K,
  TikTok 2.8K, Replit 2.7K, Smartsheet 2.1K, Duo 2.2K, Have I Been Pwned
  2.0K, Firebase 6.8K, Microsoft Dynamics 365 Marketing 2.5K. OpenAI (13K a
  week), Atlassian, Canva, DocuSign, Notion, Miro, 1Password were already
  there.

Measured on the 616 pages after the merge: 2.87 to 3.02 technologies per
page, 91 new detections on 80 pages (13% of pages), 30 of the 275 names
seen at least once; the layer costs 1.1 ms per page on top of the
detector's 17 ms. Names seen: Divi 15, Astra 11, HighLevel 7, Adobe
Experience Manager 5, Cloudflare Browser Insights 5, Hostinger Reach 5,
Bricks 3, Hostinger Website Builder 3, Kadence 3, Squarespace Commerce 3,
TrustedSite 3, Trustindex 3, Usercentrics 3, then singles.

## Who matters and who does not

Important vendors now listed that were missing: Adobe Experience Manager,
Salesforce Commerce Cloud, Shopware, VTEX, Contentful, Sanity, Liferay,
Pimcore, 1C-Bitrix, Duda, WP Engine, Pantheon, SiteGround, Bluehost,
Heroku, Fly.io, Azure, Cloudflare Workers; Braze, HighLevel, ClickFunnels,
Constant Contact, GetResponse, AWeber, Campaign Monitor, Act-On,
SharpSpring, Dotdigital, 6sense, Demandbase, Leadfeeder, Clearbit Reveal;
Amazon Pay, Google Pay, Checkout.com, Chargebee, Paddle, Klarna Checkout,
authorize.net, Cybersource; LivePerson, Freshchat, Chatra, Userlike,
Landbot; Usercentrics, Didomi, Osano, Termly; DataDome, PerimeterX, Arkose
Labs; Feefo, Trusted Shops, Stamped, Junip; Greenhouse, Lever, BambooHR,
SmartRecruiters; Cloudbeds, Mews, Fresha, Boulevard, Zenoti, Chili Piper;
Teachable, Thinkific, Moodle, Canvas LMS; Klevu, Constructor.io, Doofinder;
Contentsquare, Glassbox, Smartlook, Yandex Metrica, mParticle, Userflow.

Small or regional players that came along because the open base has a
clean pattern for them, roughly 120 of the 275: Shoptet, WiziShop, Loja
Integrada, Sylius, OXID, Hund.io, Noticeable, LaunchNotes, Momence, Tito,
Frill, Senja, Basin, Liberapay, Qgiv, Network for Good, Packlink PRO,
Track123, Commento, NodeBB, Vanilla, Linguise, most of the ad-tech SSPs.
They cost nothing to carry and nothing to maintain, and the data will say
in a month which of them appear on more than a few hundred sites.

Still missed, because their evidence is JavaScript globals, DOM or a
rendered page and the detector reads raw HTML: Adobe Analytics, Salesforce
Marketing Cloud, Adyen, Lightspeed, OpenTable, Formstack, Workable, Okendo,
Brightcove, Wistia, Clerk, Okta, Mintlify, Amazon Web Services, Google
Cloud. Twilio, Zoom, Loom and Notion are caught from DNS instead.

Names in our own list that deserve a harder look, because they say nothing
about a business and inflate the `tech_count` the revenue estimator reads:
Google Fonts (on 245 of 616 pages), Open Graph, Schema.org JSON-LD, Font
Awesome, cdnjs, jsDelivr, unpkg. Removing them changes the estimator's
inputs, so it belongs in a tuning change scored on golden v7, not here.

## Manual or automated

What the data says about the two costs:

- The open base is updated weekly by its maintainers; pulling it is a
  script run, and the curated name list is the only hand-written part.
  Refreshing it quarterly is an hour: run `build_fingerprints.py`, read the
  diff of `fingerprints.json`, run the tests. That is the manual process
  the owner already does, with the reading replaced by a diff.
- Finding what the open base does not know needs script hosts stored at
  scale. We keep page blocks and DNS, not script hosts; adding a 30-host
  array column to the fetch is a small change and the only way to rank
  unknown vendors by adoption instead of guessing. Without it, mining is
  limited to the few hundred cached golden pages, which found 9 vendors.
- An LLM is not needed for any of this. The open base names and
  categorises; adoption counts rank; a quarterly diff review decides.

Recommendation: keep it manual on a quarterly cadence with the two
scripts, and add the script-host column when the next fetch-side change
is made, so the next review ranks candidates by real adoption.
