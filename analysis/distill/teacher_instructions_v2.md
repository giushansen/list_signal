# Website labeling task (v2 taxonomy)

The batch file contains 50 websites: "### domain (tld, country)" then TITLE/H1/META, optional "TECH/SCHEMA/TRANCO_RANK" hints, then TEXT (homepage extract).

Classify EACH into exactly ONE business_model:
SaaS, Ecommerce, Agency, Consulting, LocalBusiness, Media, Education, Tool, Community, Marketplace, Newsletter, Directory, Government, Nonprofit, Manufacturer, FinancialInstitution, Junk

Definitions & DECISION RULES:
- SaaS: sells access to its own software/web product (subscription, login, API). Consumer web products count.
- Ecommerce: sells goods online with cart/checkout. TECH containing Shopify/WooCommerce/Magento/PrestaShop + shop vocabulary => Ecommerce.
- Agency: performs creative/marketing/dev/recruitment work FOR clients.
- Consulting: ADVISORY professional services only — strategy, legal, accounting, audit, tax, financial advisory, IT consulting.
- LocalBusiness: physical-world business whose site is a presence: trades, clinics, salons, gyms, restaurants, hotels, dealers, DISTRIBUTORS WITHOUT ONLINE CHECKOUT, real-estate brokerages, retail chains.
- Media: publications, news, content/affiliate sites, publishers, TV/podcasts, EVENTS & CONFERENCES, ad networks.
- Education: schools, universities, courses, training providers, edtech, driving schools.
- Tool: free/simple online utilities (calculators, converters, generators) or downloadable utilities.
- Community: forums, clubs, membership communities, associations centered on members.
- Marketplace: multi-vendor platform / booking broker connecting many independent sellers to buyers.
- Directory: search/listing sites for discovering OTHER businesses/places/jobs.
- Newsletter: the PRODUCT is an email publication (Substack tech => Newsletter). A signup box is NOT Newsletter.
- Government: government bodies at any level — ministries, agencies, municipalities, public transit, public libraries, courts, armed forces. .gov/.mil => Government unless clearly a mistake.
- Nonprofit: charities, foundations, NGOs, rescue missions, disease charities, volunteer orgs. (A club centered on members = Community; a cause serving beneficiaries = Nonprofit.)
- Manufacturer: makes physical products at industrial scale — factories, industrial equipment, CPG brands, automakers, pharma. A brand whose site is mainly a web store => Ecommerce instead.
- FinancialInstitution: banks, credit unions, insurers, asset managers, pension funds. (A fintech SaaS product => SaaS; a mortgage BROKER => Consulting.)
- Junk: parked/for-sale, hosting placeholders, default templates, coming-soon/lorem-ipsum shells, broken/empty pages, personal CVs/blogs selling nothing, PBN/guest-post farms, scam templates, demo stores.
  * Thin text + high TRANCO_RANK + branded domain usually = JS-rendered REAL org, not Junk — judge from name/tld/tech, lower confidence.

Also output: industry (short free text), revenue_bracket from exactly {"<$1M","$1M-$10M","$10M-$100M","$100M-$1B","$1B+",""} ("" only for Junk; "" also acceptable for Government), employees_bracket from {"1-10","11-50","51-200","201-1000","1000+",""}.

Non-English pages: translate mentally, label anyway.
