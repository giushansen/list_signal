# Website labeling task

The batch file contains 50 websites: "### domain (tld, country)" then TITLE/H1/META, optional "TECH/SCHEMA/TRANCO_RANK" hints, then TEXT (homepage extract).

Classify EACH into exactly ONE business_model:
SaaS, Ecommerce, Agency, Consulting, LocalBusiness, Media, Education, Tool, Community, Marketplace, Newsletter, Directory, Junk

Definitions & DECISION RULES (these settle the common boundary cases — follow them exactly):
- SaaS: sells access to its own software/web product (subscription, login, API). Consumer web products count.
- Ecommerce: sells goods online with cart/checkout. TECH containing Shopify/WooCommerce/Magento/PrestaShop + shop vocabulary => Ecommerce.
- Agency: performs creative/marketing/dev/recruitment work FOR clients (web design studios, video production, staffing agencies).
- Consulting: ADVISORY professional services only — strategy, legal, accounting, audit, tax, financial advisory, IT consulting.
- LocalBusiness: physical-world business whose site is a presence: trades (plumber, glazier, joinery, landscaper, printer, drilling), clinics/practices, salons, gyms, restaurants, hotels, car dealers, DISTRIBUTORS/DEALERS WITHOUT ONLINE CHECKOUT, real-estate brokerages selling their own/managed inventory, retail chains.
  * trade/venue + no cart => LocalBusiness, never Consulting/Agency/Ecommerce.
- Media: publications, news, content/affiliate sites, publishers, TV/podcasts, EVENTS & CONFERENCES, ad networks, blogs that are the business.
- Education: schools, universities, courses, training providers, edtech, driving schools, kids academies.
- Tool: free/simple online utilities (calculators, converters, generators) or downloadable utilities.
- Community: forums, clubs, associations, membership communities, nonprofits centered on members.
- Marketplace: multi-vendor platform / booking broker connecting many independent sellers to buyers.
- Directory: search/listing sites for discovering OTHER businesses/places/jobs (not their own inventory).
- Newsletter: the PRODUCT is an email publication (Substack tech => Newsletter). A signup box on any site is NOT Newsletter.
- Junk: parked/for-sale, hosting placeholders, default templates, coming-soon/lorem-ipsum shells, broken/empty, personal CVs/blogs selling nothing, PBN/guest-post farms, scam templates, demo stores.
  * Thin text + high TRANCO_RANK + branded domain usually = JS-rendered REAL business, not Junk — judge from name/tld/tech, lower confidence.

Also output: industry (short free text), revenue_bracket from exactly {"<$1M","$1M-$10M","$10M-$100M","$100M-$1B","$1B+",""} (gut feel; big chains/brands/banks go high; "" only for Junk), employees_bracket from {"1-10","11-50","51-200","201-1000","1000+",""}.

Non-English pages: translate mentally, label anyway.
