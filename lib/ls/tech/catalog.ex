defmodule LS.Tech.Catalog do
  @moduledoc """
  The closed list of technology names the product publishes, with a category
  and an ecosystem per name (data model v2, 2026-10-01).

  Why a closed list: the tech detector only ever emits one of its ~230 fixed
  names, but the Shopify app detector title-cases theme-extension handles
  into names, which produced 7,304 distinct "apps" in production of which
  6,262 appeared on fewer than 100 stores ("Xb Quote Request", "Notify Me
  Ninja Htn"). One array, `http_tech`, now carries platforms, vendors,
  WordPress plugins and Shopify apps alike, and only names in this list
  enter it. Raw Shopify handles stay in `http_shopify_app_handles` so a
  name added here backfills by SQL without a recrawl.

  The same list is loaded into the `tech_catalog` ClickHouse table on
  master boot (`LS.Tech.CatalogSync`) so the compactor fold, the v1 to v2
  transform and the explorer's "Shopify apps" category filter all read the
  one list. Workers never read that table; they ship this module.

  Aliases map the names older rows carry (humanised handles, pre-2026-10
  spellings) to the canonical name; the fold applies them before the filter.
  """

  @type entry :: {String.t(), atom(), String.t()}

  # {name, category, ecosystem}. Ecosystem "" means a general vendor; a
  # named ecosystem marks an add-on that means nothing outside its platform.
  @entries [
    # platforms
    {"Shopify", :platform, ""}, {"WordPress", :platform, ""}, {"Wix", :platform, ""}, {"Squarespace", :platform, ""},
    {"Webflow", :platform, ""}, {"GoDaddy Builder", :platform, ""}, {"Weebly", :platform, ""}, {"Framer", :platform, ""},
    {"Tilda", :platform, ""}, {"Readymag", :platform, ""}, {"Bubble", :platform, ""}, {"Carrd", :platform, ""},
    {"Substack", :platform, ""}, {"Ghost", :platform, ""}, {"Notion", :platform, ""}, {"Builder.io", :platform, ""},
    {"Shift4Shop", :platform, ""}, {"BigCommerce", :platform, ""}, {"Volusion", :platform, ""}, {"Ecwid", :platform, ""},
    {"Odoo", :platform, ""},
    # ecommerce
    {"WooCommerce", :ecommerce, ""}, {"Magento", :ecommerce, ""}, {"PrestaShop", :ecommerce, ""}, {"OpenCart", :ecommerce, ""},
    {"Snipcart", :ecommerce, ""}, {"FoxyCart", :ecommerce, ""}, {"Fast Simon", :search, ""}, {"Searchspring", :search, ""},
    {"Searchanise", :search, ""}, {"Algolia", :search, ""}, {"Clerk.io", :search, ""},
    # cms and site generators
    {"Joomla", :cms, ""}, {"Drupal", :cms, ""}, {"TYPO3", :cms, ""}, {"Concrete CMS", :cms, ""}, {"Contao", :cms, ""},
    {"Craft CMS", :cms, ""}, {"Umbraco", :cms, ""}, {"Sitefinity", :cms, ""}, {"Sitecore", :cms, ""}, {"Kentico", :cms, ""},
    {"Episerver", :cms, ""}, {"dotCMS", :cms, ""}, {"Strapi", :cms, ""}, {"Prismic", :cms, ""}, {"Storyblok", :cms, ""},
    {"Hugo", :cms, ""}, {"Jekyll", :cms, ""}, {"Hexo", :cms, ""}, {"Eleventy", :cms, ""}, {"Pelican", :cms, ""},
    {"Gatsby", :cms, ""}, {"Astro", :framework, ""},
    # frameworks and languages
    {"Next.js", :framework, ""}, {"Nuxt.js", :framework, ""}, {"React", :framework, ""}, {"Vue.js", :framework, ""},
    {"AngularJS", :framework, ""}, {"Angular", :framework, ""}, {"Svelte", :framework, ""}, {"Remix", :framework, ""},
    {"Express", :framework, ""}, {"Laravel", :framework, ""}, {"Ruby on Rails", :framework, ""}, {"Django", :framework, ""},
    {"Flask", :framework, ""}, {"FastAPI", :framework, ""}, {"Symfony", :framework, ""}, {"CodeIgniter", :framework, ""},
    {"CakePHP", :framework, ""}, {"ASP.NET", :framework, ""}, {"PHP", :framework, ""}, {"Java", :framework, ""},
    {"Phoenix", :framework, ""}, {"htmx", :framework, ""}, {"Alpine.js", :framework, ""}, {"Tailwind CSS", :framework, ""},
    {"Bootstrap", :framework, ""}, {"Foundation", :framework, ""}, {"Materialize", :framework, ""}, {"Bulma", :framework, ""},
    {"UIKit", :framework, ""}, {"Semantic UI", :framework, ""},
    # servers
    {"Nginx", :server, ""}, {"Apache", :server, ""}, {"LiteSpeed", :server, ""}, {"OpenResty", :server, ""}, {"IIS", :server, ""},
    {"Caddy", :server, ""}, {"Cowboy", :server, ""}, {"Gunicorn", :server, ""}, {"Kestrel", :server, ""}, {"Envoy", :server, ""},
    {"Jetty", :server, ""}, {"Tomcat", :server, ""}, {"Traefik", :server, ""}, {"Deno", :server, ""}, {"Tornado", :server, ""},
    # cdn and asset hosts
    {"Cloudflare", :cdn, ""}, {"Fastly", :cdn, ""}, {"Google Cloud CDN", :cdn, ""}, {"CloudFront", :cdn, ""}, {"Akamai", :cdn, ""},
    {"Imperva", :cdn, ""}, {"BunnyCDN", :cdn, ""}, {"Azure CDN", :cdn, ""}, {"KeyCDN", :cdn, ""}, {"StackPath", :cdn, ""},
    {"cdnjs", :cdn, ""}, {"jsDelivr", :cdn, ""}, {"unpkg", :cdn, ""}, {"Imgix", :cdn, ""}, {"Cloudinary", :cdn, ""},
    # hosting
    {"Vercel", :hosting, ""}, {"Netlify", :hosting, ""}, {"Render", :hosting, ""}, {"Supabase", :hosting, ""}, {"Firebase", :hosting, ""},
    # analytics and product analytics
    {"Google Analytics", :analytics, ""}, {"Google Tag Manager", :analytics, ""}, {"Matomo", :analytics, ""}, {"Plausible", :analytics, ""},
    {"Hotjar", :analytics, ""}, {"Microsoft Clarity", :analytics, ""}, {"Crazy Egg", :analytics, ""}, {"Amplitude", :analytics, ""},
    {"Mixpanel", :analytics, ""}, {"Heap", :analytics, ""}, {"FullStory", :analytics, ""}, {"LogRocket", :analytics, ""},
    {"Mouseflow", :analytics, ""}, {"Lucky Orange", :analytics, ""}, {"Segment", :analytics, ""}, {"Rudderstack", :analytics, ""},
    {"PostHog", :analytics, ""}, {"Adobe Launch", :analytics, ""}, {"Adobe RUM", :analytics, ""}, {"Tealium", :analytics, ""},
    {"SpeedCurve", :analytics, ""}, {"Datadog", :analytics, ""}, {"New Relic", :analytics, ""}, {"Sentry", :analytics, ""},
    {"Rollbar", :analytics, ""}, {"Pendo", :analytics, ""}, {"Appcues", :analytics, ""}, {"UserPilot", :analytics, ""},
    {"Littledata", :analytics, "shopify"}, {"Independent Analytics", :analytics, "wordpress"}, {"MonsterInsights", :analytics, "wordpress"},
    {"Google Site Kit", :analytics, "wordpress"}, {"PixelYourSite", :analytics, "wordpress"}, {"WeTracked", :analytics, "shopify"},
    # ads
    {"Google AdSense", :ads, ""}, {"Meta Pixel", :ads, ""}, {"Google Publisher Tag", :ads, ""}, {"DoubleClick", :ads, ""},
    {"Microsoft Advertising", :ads, ""}, {"Pinterest Tag", :ads, ""}, {"LinkedIn Insight", :ads, ""}, {"Twitter Pixel", :ads, ""},
    {"TikTok Pixel", :ads, ""}, {"Snapchat Pixel", :ads, ""}, {"Reddit Pixel", :ads, ""}, {"Quora Pixel", :ads, ""},
    {"Criteo", :ads, ""}, {"Taboola", :ads, ""}, {"Outbrain", :ads, ""}, {"Media.net", :ads, ""}, {"AdRoll", :ads, ""}, {"MGID", :ads, ""},
    # marketing, email, crm
    {"Klaviyo", :marketing, ""}, {"HubSpot", :marketing, ""}, {"HubSpot Forms", :marketing, "hubspot"}, {"HubSpot CMS", :marketing, "hubspot"},
    {"HubSpot Chat", :marketing, "hubspot"}, {"HubSpot Meetings", :marketing, "hubspot"}, {"HubSpot CTA", :marketing, "hubspot"},
    {"HubSpot Ads", :marketing, "hubspot"}, {"HubSpot Cookie Banner", :marketing, "hubspot"}, {"HubSpot Feedback", :marketing, "hubspot"},
    {"Mailchimp", :marketing, ""}, {"Brevo", :marketing, ""}, {"Omnisend", :marketing, ""}, {"Attentive", :marketing, ""},
    {"ConvertKit", :marketing, ""}, {"MailerLite", :marketing, ""}, {"Marketo", :marketing, ""}, {"Pardot", :marketing, ""},
    {"ActiveCampaign", :marketing, ""}, {"Drip", :marketing, ""}, {"Customer.io", :marketing, ""}, {"Postscript", :marketing, ""},
    {"Optimizely", :ab_testing, ""}, {"VWO", :ab_testing, ""}, {"AB Tasty", :ab_testing, ""}, {"Dynamic Yield", :ab_testing, ""},
    {"Convert", :ab_testing, ""}, {"Typeform", :forms, ""}, {"JotForm", :forms, ""}, {"OptinMonster", :marketing, "wordpress"},
    {"OptiMonk", :marketing, ""}, {"Poptin", :marketing, ""}, {"Privy", :marketing, "shopify"}, {"Seguno", :marketing, "shopify"},
    {"Hustle", :marketing, "wordpress"}, {"MailPoet", :marketing, "wordpress"}, {"MC4WP Mailchimp", :marketing, "wordpress"},
    {"Mailchimp WooCommerce", :marketing, "wordpress"}, {"Sumo", :marketing, ""}, {"OneSignal", :marketing, ""},
    {"Getsitecontrol", :marketing, ""}, {"PopConvert", :marketing, "shopify"}, {"Conversion Bear", :marketing, "shopify"},
    {"ProveSource", :marketing, ""}, {"Hoppy", :marketing, "shopify"}, {"PushOwl", :marketing, "shopify"},
    # mailbox providers
    {"Google Workspace", :email, ""}, {"Microsoft 365", :email, ""},
    # chat and support
    {"Tidio", :chat, ""}, {"Tawk.to", :chat, ""}, {"Crisp", :chat, ""}, {"LiveChat", :chat, ""}, {"Intercom", :chat, ""},
    {"Drift", :chat, ""}, {"Zendesk", :chat, ""}, {"Freshworks", :chat, ""}, {"Help Scout", :chat, ""}, {"Zoho SalesIQ", :chat, ""},
    {"Olark", :chat, ""}, {"Smooch", :chat, ""}, {"Gorgias", :chat, ""}, {"Dondy WhatsApp Chat", :chat, "shopify"}, {"MooseDesk", :chat, "shopify"},
    # payments
    {"Stripe", :payments, ""}, {"PayPal", :payments, ""}, {"Afterpay", :payments, ""}, {"Klarna", :payments, ""}, {"Sezzle", :payments, ""},
    {"Razorpay", :payments, ""}, {"Square", :payments, ""}, {"Braintree", :payments, ""}, {"Mollie", :payments, ""}, {"Affirm", :payments, ""},
    {"Scalapay", :payments, ""}, {"Mercado Pago", :payments, ""}, {"Shop Pay", :payments, "shopify"}, {"WooCommerce Payments", :payments, "wordpress"},
    {"WooCommerce Stripe", :payments, "wordpress"},
    # subscriptions, loyalty, reviews (commerce add-ons)
    {"ReCharge", :subscriptions, ""}, {"Appstle", :subscriptions, "shopify"}, {"Skio", :subscriptions, "shopify"}, {"Recurpay", :subscriptions, "shopify"},
    {"WooCommerce Subscriptions", :subscriptions, "wordpress"}, {"WooCommerce Memberships", :subscriptions, "wordpress"},
    {"Smile.io", :loyalty, "shopify"}, {"LoyaltyLion", :loyalty, "shopify"}, {"Rivo", :loyalty, "shopify"}, {"Joy Loyalty", :loyalty, "shopify"},
    {"Growave", :loyalty, "shopify"}, {"Yotpo Reviews", :reviews, ""}, {"Judge.me", :reviews, "shopify"}, {"Loox", :reviews, "shopify"},
    {"Stamped.io", :reviews, "shopify"}, {"Trustpilot", :reviews, ""}, {"Shopify Product Reviews", :reviews, "shopify"},
    {"Ali Reviews", :reviews, "shopify"}, {"Ryviu", :reviews, "shopify"}, {"Rivyo", :reviews, "shopify"}, {"Reviews.io", :reviews, ""},
    {"Trustoo Reviews", :reviews, "shopify"}, {"Fera", :reviews, "shopify"}, {"Reputon", :reviews, "shopify"}, {"Air Reviews", :reviews, "shopify"},
    # shopify storefront apps
    {"PageFly", :builder, "shopify"}, {"GemPages", :builder, "shopify"}, {"Shogun", :builder, "shopify"}, {"Ecomposer", :builder, "shopify"},
    {"Hextom", :upsell, "shopify"}, {"UpCart", :upsell, "shopify"}, {"Rebuy", :upsell, "shopify"}, {"Kaching", :upsell, "shopify"},
    {"LB Upsell", :upsell, "shopify"}, {"FoxKit", :upsell, "shopify"}, {"Essential Apps", :upsell, "shopify"}, {"AfterSell", :upsell, "shopify"},
    {"Monster Upsells", :upsell, "shopify"}, {"Candyrack", :upsell, "shopify"}, {"Fast Bundle", :upsell, "shopify"}, {"Vitals", :upsell, "shopify"},
    {"Opus", :upsell, "shopify"}, {"Monk", :upsell, "shopify"}, {"Bold Commerce", :upsell, "shopify"}, {"Discounty", :upsell, "shopify"},
    {"Dealeasy", :upsell, "shopify"}, {"FreeGifts", :upsell, "shopify"}, {"Cartbite", :upsell, "shopify"}, {"Avada", :upsell, "shopify"},
    {"Wishlist Plus", :wishlist, "shopify"}, {"Wishlist Hero", :wishlist, "shopify"}, {"Wishlist King", :wishlist, "shopify"}, {"Swym Relay", :wishlist, "shopify"},
    {"Ecomsend", :marketing, "shopify"}, {"Restock Rocket", :marketing, "shopify"}, {"Back in Stock", :marketing, "shopify"}, {"Appikon", :marketing, "shopify"},
    {"Timesact", :marketing, "shopify"}, {"PreOrder Now", :marketing, "shopify"}, {"Instafeed", :social, "shopify"}, {"ReelUp", :social, "shopify"},
    {"Reelfy", :social, "shopify"}, {"Whatmore", :social, "shopify"}, {"Lookfy", :social, "shopify"}, {"Globo", :product_options, "shopify"},
    {"HulkApps Form Builder", :forms, "shopify"}, {"HulkApps Product Options", :product_options, "shopify"}, {"HulkApps Volume Discount", :upsell, "shopify"},
    {"Powerful Form Builder", :forms, "shopify"}, {"Easify", :product_options, "shopify"}, {"BSS Commerce", :product_options, "shopify"},
    {"Customily", :product_options, "shopify"}, {"GLO Color Swatch", :product_options, "shopify"}, {"Transcy", :translation, "shopify"},
    {"LangShop", :translation, "shopify"}, {"Langify", :translation, "shopify"}, {"Weglot", :translation, ""}, {"WPML", :translation, "wordpress"},
    {"TranslatePress", :translation, "wordpress"}, {"Polylang", :translation, "wordpress"}, {"BUCKS Currency Converter", :localization, "shopify"},
    {"Beast Currency Converter", :localization, "shopify"}, {"Nova Currency Converter", :localization, "shopify"}, {"Orbe", :localization, "shopify"},
    {"Releasit COD Form", :checkout, "shopify"}, {"EasySell", :checkout, "shopify"}, {"Zapiet", :shipping, "shopify"}, {"Route", :shipping, "shopify"},
    {"Loop Returns", :shipping, "shopify"}, {"CJdropshipping", :shipping, "shopify"}, {"Printify", :shipping, "shopify"}, {"Gelato", :shipping, "shopify"},
    {"Wholesale Gorilla", :b2b, "shopify"}, {"Secomapp Affiliate", :affiliate, "shopify"}, {"UpPromote", :affiliate, "shopify"},
    {"BixGrow", :affiliate, "shopify"}, {"RevenueHunt", :marketing, "shopify"}, {"Cowlendar", :scheduling, "shopify"}, {"Appointo", :scheduling, "shopify"},
    {"Stape", :analytics, "shopify"}, {"Seowill AI SEO", :seo, "shopify"}, {"Tapita", :seo, "shopify"}, {"Buddha Mega Menu", :builder, "shopify"},
    {"Qikify", :builder, "shopify"}, {"Fontify", :builder, "shopify"}, {"Propel", :analytics, "shopify"}, {"Omega", :product_options, "shopify"},
    {"Froonze", :loyalty, "shopify"}, {"Accessibly", :accessibility, "shopify"}, {"Consentik", :consent, "shopify"}, {"Consentmo GDPR", :consent, "shopify"},
    {"GDPR Cookie Consent", :consent, "shopify"}, {"Apphero", :marketing, "shopify"},
    # wordpress plugins
    {"Elementor", :builder, "wordpress"}, {"Yoast SEO", :seo, "wordpress"}, {"Contact Form 7", :forms, "wordpress"}, {"Slider Revolution", :builder, "wordpress"},
    {"All in One SEO", :seo, "wordpress"}, {"WPForms", :forms, "wordpress"}, {"WPForms Pro", :forms, "wordpress"}, {"WP-PageNavi", :builder, "wordpress"},
    {"WP Rocket", :performance, "wordpress"}, {"WPBakery", :builder, "wordpress"}, {"Gravity Forms", :forms, "wordpress"}, {"Complianz", :consent, "wordpress"},
    {"Jetpack", :builder, "wordpress"}, {"LiteSpeed Cache", :performance, "wordpress"}, {"CookieYes", :consent, ""}, {"Smash Balloon Instagram", :social, "wordpress"},
    {"Smash Balloon Facebook", :social, "wordpress"}, {"Smash Balloon YouTube", :social, "wordpress"}, {"WP Super Cache", :performance, "wordpress"},
    {"Cookie Notice", :consent, "wordpress"}, {"W3 Total Cache", :performance, "wordpress"}, {"Fluent Forms", :forms, "wordpress"},
    {"Kadence Blocks", :builder, "wordpress"}, {"bbPress", :community, "wordpress"}, {"BuddyPress", :community, "wordpress"}, {"Smush", :performance, "wordpress"},
    {"Smart Slider 3", :builder, "wordpress"}, {"Beaver Builder", :builder, "wordpress"}, {"Beaver Builder Pro", :builder, "wordpress"},
    {"TablePress", :builder, "wordpress"}, {"EWWW Optimizer", :performance, "wordpress"}, {"GDPR Cookie Compliance", :consent, "wordpress"},
    {"MetaSlider", :builder, "wordpress"}, {"Formidable Forms", :forms, "wordpress"}, {"Akismet", :security, "wordpress"}, {"Avada Builder", :builder, "wordpress"},
    {"AddToAny Share", :social, "wordpress"}, {"Breeze", :performance, "wordpress"}, {"Forminator", :forms, "wordpress"}, {"Autoptimize", :performance, "wordpress"},
    {"Ninja Forms", :forms, "wordpress"}, {"Perfmatters", :performance, "wordpress"}, {"Oxygen Builder", :builder, "wordpress"}, {"Tutor LMS", :lms, "wordpress"},
    {"LearnDash", :lms, "wordpress"}, {"LifterLMS", :lms, "wordpress"}, {"Sensei LMS", :lms, "wordpress"}, {"Stackable", :builder, "wordpress"},
    {"Everest Forms", :forms, "wordpress"}, {"Paid Memberships Pro", :subscriptions, "wordpress"}, {"MemberPress", :subscriptions, "wordpress"},
    {"Restrict Content Pro", :subscriptions, "wordpress"}, {"Easy Digital Downloads", :ecommerce, "wordpress"}, {"NextGEN Gallery", :builder, "wordpress"},
    {"Envira Gallery", :builder, "wordpress"}, {"Modula Gallery", :builder, "wordpress"}, {"Divi Builder", :builder, "wordpress"}, {"AIOS Security", :security, "wordpress"},
    {"Wordfence", :security, "wordpress"}, {"SG Optimizer", :performance, "wordpress"}, {"FlyingPress", :performance, "wordpress"}, {"Optimole", :performance, "wordpress"},
    {"WooCommerce Bookings", :scheduling, "wordpress"}, {"WooCommerce Blocks", :ecommerce, "wordpress"}, {"CheckoutWC", :checkout, "wordpress"},
    {"Schema Pro", :seo, "wordpress"}, {"Rank Math", :seo, "wordpress"}, {"Social Warfare", :social, "wordpress"}, {"ACF", :builder, "wordpress"},
    {"ACF Pro", :builder, "wordpress"},
    # security, consent, accessibility
    {"reCAPTCHA", :security, ""}, {"Cloudflare Turnstile", :security, ""}, {"hCaptcha", :security, ""}, {"Sucuri", :security, ""},
    {"Cookiebot", :consent, ""}, {"OneTrust", :consent, ""}, {"TrustArc", :consent, ""}, {"iubenda", :consent, ""}, {"Cookie Script", :consent, ""},
    {"UserWay", :accessibility, ""}, {"accessiBe", :accessibility, ""}, {"EqualWeb", :accessibility, ""},
    # seo signals
    {"Google Search Console", :seo, ""}, {"Open Graph", :seo, ""}, {"Schema.org JSON-LD", :seo, ""},
    # fonts and front-end libraries
    {"Google Fonts", :fonts, ""}, {"Adobe Fonts", :fonts, ""}, {"Font Awesome", :fonts, ""},
    {"jQuery", :library, ""}, {"Swiper", :library, ""}, {"Slick", :library, ""}, {"GSAP", :library, ""}, {"AOS", :library, ""},
    {"Owl Carousel", :library, ""}, {"Popper.js", :library, ""}, {"SweetAlert2", :library, ""}, {"Fancybox", :library, ""},
    {"Select2", :library, ""}, {"Moment.js", :library, ""}, {"Chart.js", :library, ""}, {"Flatpickr", :library, ""}, {"Toastr", :library, ""},
    {"Three.js", :library, ""}, {"Isotope", :library, ""}, {"Axios", :library, ""}, {"Lightbox2", :library, ""}, {"Anime.js", :library, ""},
    {"Lottie", :library, ""}, {"Masonry", :library, ""}, {"GLightbox", :library, ""}, {"Prism.js", :library, ""}, {"Lodash", :library, ""},
    {"Flickity", :library, ""}, {"Highlight.js", :library, ""}, {"D3.js", :library, ""}, {"Pusher", :library, ""}, {"Sortable.js", :library, ""},
    {"Socket.IO", :library, ""}, {"Choices.js", :library, ""}, {"Tippy.js", :library, ""}, {"Ably", :library, ""},
    # maps, video, social embeds
    {"Google Maps", :maps, ""}, {"Mapbox", :maps, ""}, {"HERE Maps", :maps, ""}, {"Leaflet", :maps, ""},
    {"YouTube", :video, ""}, {"Vimeo", :video, ""}, {"Wistia", :video, ""}, {"Brightcove", :video, ""}, {"Vidyard", :video, ""}, {"JW Player", :video, ""},
    {"Facebook SDK", :social, ""}, {"Twitter Widgets", :social, ""}, {"Instagram Embed", :social, ""},
    # auth and scheduling
    {"Supabase Auth", :auth, ""}, {"Clerk", :auth, ""}, {"Firebase Auth", :auth, ""}, {"Auth0", :auth, ""}, {"NextAuth", :auth, ""},
    {"Okta", :auth, ""}, {"WorkOS", :auth, ""}, {"AWS Cognito", :auth, ""}, {"Stytch", :auth, ""}, {"Calendly", :scheduling, ""}
  ]

  # Older spellings and humanised Shopify handles -> canonical name.
  @aliases %{
    "Judgeme" => "Judge.me",
    "Pagefly Ai Page Builder" => "PageFly",
    "Klaviyo Email Marketing" => "Klaviyo",
    "Upcart" => "UpCart",
    "Pushowl" => "PushOwl",
    "Releasit Cod Form" => "Releasit COD Form",
    "Releasit Cod Fee" => "Releasit COD Form",
    "Gempages Cro" => "GemPages",
    "Complianz Gdpr Cookie Consent" => "Complianz",
    "Hextom Sales Boost" => "Hextom",
    "Free Shipping Bar" => "Hextom",
    "Avada Seo Suite" => "Avada",
    "Avada Faqs" => "Avada",
    "Avada Cookie Bar" => "Avada",
    "Avada Boost Sales" => "Avada",
    "Avada Order Limit" => "Avada",
    "Avada Upsell" => "Avada",
    "Essential Post Purchase Upsell" => "Essential Apps",
    "Essential Announcement Bar" => "Essential Apps",
    "Essential Cart Drawer" => "Essential Apps",
    "Essential Pre Order Presale" => "Essential Apps",
    "Essential Icon Badge Banners" => "Essential Apps",
    "Essentials Estimated Delivery" => "Essential Apps",
    "Stape Remix" => "Stape",
    "Getsitecontrol Countdown Timer" => "Getsitecontrol",
    "Easify Product Options" => "Easify",
    "Bucks Currency Converter" => "BUCKS Currency Converter",
    "Announcement Bar Maker By Apphero" => "Apphero",
    "Apphero Free Gift" => "Apphero",
    "Pop Convert" => "PopConvert",
    "Cwilltrustoo Reviews" => "Trustoo Reviews",
    "Fontify Polaris" => "Fontify",
    "Fera.ai" => "Fera",
    "Glo Color Swatch" => "GLO Color Swatch",
    "Reputon Google Reviews Widget" => "Reputon",
    "Aftersell" => "AfterSell",
    "Freegifts" => "FreeGifts",
    "Nova Multi Currency Converter" => "Nova Currency Converter",
    "Orbe Geolocation" => "Orbe",
    "Klarna On Site Messaging" => "Klarna",
    "Tapita Seo Speed" => "Tapita",
    "Buddha Mega Menu Navigation" => "Buddha Mega Menu",
    "Back In Stock" => "Back in Stock",
    "Back In Stock Restock" => "Back in Stock",
    "Ecomsend Restock" => "Ecomsend",
    "Kaching Cart" => "Kaching",
    "Kaching Bundles" => "Kaching",
    "Kaching Subscriptions" => "Kaching",
    "Bixgrow Affiliate" => "BixGrow",
    "Accessibly App" => "Accessibly",
    "Rivo Loyalty Rewards Referrals" => "Rivo",
    "Affirm Pay Over Time Messaging" => "Affirm",
    "Mercadopago Pf App" => "Mercado Pago",
    "Reviews Co Uk Product And Merchant Review Collection" => "Reviews.io",
    "Easysell Cod Form" => "EasySell",
    "Product Options By Bss" => "BSS Commerce",
    "Revenuehunt" => "RevenueHunt",
    "Joy Loyalty Program" => "Joy Loyalty",
    "Swish Wishlist King" => "Wishlist King",
    "Facebook Pixel" => "Meta Pixel",
    "Lookfy Lookbook Gallery" => "Lookfy",
    "Zapiet Pickup Delivery" => "Zapiet",
    "Product Options By Hulkapps" => "HulkApps Product Options",
    "Form Builder By Hulkapps" => "HulkApps Form Builder",
    "Volume Discount By Hulkapps" => "HulkApps Volume Discount",
    "Propel Replays" => "Propel",
    "Reelup" => "ReelUp",
    "Preorder Now Wolf" => "PreOrder Now",
    "Preorder Now" => "PreOrder Now",
    "Hoppy Free Shipping" => "Hoppy",
    "Hoppy Popups" => "Hoppy",
    "Hoppy Trust Badges" => "Hoppy",
    "Conversionbear Salespop" => "Conversion Bear",
    "Fast Bundle Product Bundles" => "Fast Bundle",
    "Seguno Popups" => "Seguno",
    "Consentik Ex" => "Consentik",
    "Whatmorelive" => "Whatmore",
    "Afterpay On Site Messaging" => "Afterpay",
    "Booster Kit By Qikify" => "Qikify",
    "Appstle Bundles" => "Appstle",
    "Appstle Subscriptions" => "Appstle",
    "Request For Quote By Omega" => "Omega",
    "Age Verifier By Omega" => "Omega",
    "Scalapay Widget Installer Prod" => "Scalapay",
    "Monk Free Gift With Purchase" => "Monk",
    "Opus Cart Drawer Cart Upsell" => "Opus",
    "Moosedesk Whatsapp" => "MooseDesk",
    "Globo Also Bought Cross Sell" => "Globo",
    "Globo Product Options" => "Globo",
    "Gelato Print On Demand" => "Gelato",
    "Froonze App" => "Froonze",
    "Rivyo Product Review" => "Rivyo",
    "Appikon Back In Stock" => "Appikon",
    "Rebuy Personalization Engine" => "Rebuy",
    "Lb Upsell" => "LB Upsell",
    "Foxkit Upsell Bundles" => "FoxKit",
    "Affliate By Secomapp" => "Secomapp Affiliate",
    "Dondy Whatsapp Chat Widget" => "Dondy WhatsApp Chat",
    "Seowill Ai Seo" => "Seowill AI SEO",
    "Seowill Page Speed" => "Seowill AI SEO",
    "Bold" => "Bold Commerce",
    "Restockrocket" => "Restock Rocket",
    "HubSpot Tracking" => "HubSpot",
    "Matomo Analytics" => "Matomo",
    "wetracked" => "WeTracked",
    "Gdpr Cookie Consent" => "GDPR Cookie Consent",
    "Wishlist Engine" => "Wishlist Plus"
  }

  @names MapSet.new(Enum.map(@entries, &elem(&1, 0)))
  @by_name Map.new(@entries, fn {n, cat, eco} -> {n, {cat, eco}} end)

  @doc "Every entry, `{name, category, ecosystem}`."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Canonical names."
  def names, do: Enum.map(@entries, &elem(&1, 0))

  @doc "The alias map, older spelling -> canonical."
  def aliases, do: @aliases

  @doc "Canonical form of a detected name: alias resolved, or the name itself."
  def canonical(name) when is_binary(name), do: Map.get(@aliases, name, name)

  @doc "Whether a (canonical) name is published."
  def known?(name) when is_binary(name), do: MapSet.member?(@names, name)

  @doc "Category and ecosystem of a canonical name, or nil."
  def info(name), do: Map.get(@by_name, name)

  @doc "Names that belong to a platform's add-on ecosystem (plugins and apps)."
  def app_names, do: for({n, _, eco} <- @entries, eco != "", do: n)

  @doc "Names in one ecosystem, for a category filter."
  def names_in(ecosystem) when is_binary(ecosystem), do: for({n, _, eco} <- @entries, eco == ecosystem, do: n)

  @doc """
  Canonicalise and filter a list of detected names: aliases resolved,
  unknown names dropped, duplicates removed, order kept.
  """
  @spec publish([String.t()]) :: [String.t()]
  def publish(names) when is_list(names) do
    names
    |> Enum.map(&canonical/1)
    |> Enum.filter(&known?/1)
    |> Enum.uniq()
  end

  @doc "Rows for the `tech_catalog` ClickHouse table: `{name, category, ecosystem}` as strings."
  def table_rows, do: for({n, cat, eco} <- @entries, do: {n, Atom.to_string(cat), eco})

  @doc "The alias arrays for ClickHouse `transform(x, from, to, x)`."
  def alias_arrays do
    {from, to} = @aliases |> Enum.sort() |> Enum.unzip()
    {from, to}
  end
end
