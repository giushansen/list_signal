defmodule LS.HTTP.AppDetector do
  @moduledoc "Detect Shopify apps and WordPress plugins from HTML source."

  def detect(body \\ "", tech \\ [])

  def detect(body, _tech) when is_binary(body) do
    html = String.downcase(body)
    apps = []
      |> detect_shopify_apps(html)
      |> detect_wp_plugins(html)
      |> Enum.uniq() |> Enum.sort()
    %{apps: apps}
  end

  def detect(_, _), do: %{apps: []}

  @shopify_domains [
    # Reviews & UGC (sorted by install count)
    {"cdn.judge.me", "Judge.me"},
    {"staticw2.yotpo.com", "Yotpo Reviews"},
    {"cdn-widgetsrepository.yotpo.com", "Yotpo Reviews"},
    {"productreviews.shopifycdn.com", "Shopify Product Reviews"},
    {"loox.io", "Loox"},
    {"cdn1.stamped.io", "Stamped.io"},
    {"stamped.io/assets", "Stamped.io"},
    {"cdn.okereviews.com", "Okendo"},
    {"d3hw6dc1ow8pp2.cloudfront.net/reviewsio", "Reviews.io"},
    {"widget.trustpilot.com", "Trustpilot"},
    {"cdn.reviewscofe.com", "Rivyo Reviews"},
    {"cdn.fera.ai", "Fera.ai"},
    {"cdn.ryviu.com", "Ryviu"},
    {"alireviews.fireapps.io", "Ali Reviews"},
    # Email & SMS Marketing
    {"static.klaviyo.com", "Klaviyo"},
    {"omnisnippet1.com", "Omnisend"},
    {"omnisrc.com", "Omnisend"},
    {"cdn.sendlane.com", "Sendlane"},
    {"assets.mailerlite.com", "MailerLite"},
    {"app.drip.com", "Drip"},
    {"cdn.postscript.io", "Postscript"},
    {"cdn.attn.tv", "Attentive"},
    {"attentive.com/dtag", "Attentive"},
    {"cdn.shopify.com/proxy/brevo", "Brevo"},
    {"chimpstatic.com", "Mailchimp"},
    {"list-manage.com", "Mailchimp"},
    {"f.convertkit.com", "ConvertKit"},
    {"generic-mailmunch", "MailMunch"},
    {"cdn.pushowl.com", "PushOwl"},
    {"onesignal.com", "OneSignal"},
    {"cdn.seguno.com", "Seguno"},
    {"cdn.sendwithus.com", "Sendwithus"},
    {"go.flodesk.com", "Flodesk"},
    # Popups & Conversion
    {"widget.privy.com", "Privy"},
    {"cdn.justuno.com", "Justuno"},
    {"front.optimonk.com", "OptiMonk"},
    {"onsite.optimonk.com", "OptiMonk"},
    {"app.wisepops.com", "Wisepops"},
    {"assets.wheelio-app.com", "Wheelio"},
    {"cdn.popt.in", "Poptin"},
    {"cdn.rivo.io", "Rivo Popups"},
    {"generic-mailmunch", "MailMunch"},
    {"sumo.com/sumo.js", "Sumo"},
    {"load.sumo.com", "Sumo"},
    {"optinmonster.com", "OptinMonster"},
    # Loyalty & Rewards
    {"js.smile.io", "Smile.io"},
    {"sdk.loyaltylion.net", "LoyaltyLion"},
    {"loyaltylion.com", "LoyaltyLion"},
    {"cdn.yotpo.com/widgets/loyalty", "Yotpo Loyalty"},
    {"cdn.rivo.io", "Rivo"},
    {"cdn.growave.io", "Growave"},
    # Page Builders
    {"pagefly.io", "PageFly"},
    {"getshogun.com", "Shogun"},
    {"lib.getshogun.com", "Shogun"},
    {"gempages.net", "GemPages"},
    {"cdn.zipify.com/zipifypages", "Zipify Pages"},
    {"cdn.ecomposer.io", "EComposer"},
    {"replo.app", "Replo"},
    # Subscriptions
    {"rechargepayments.com", "ReCharge"},
    {"boldcommerce.com", "Bold Commerce"},
    {"boldapps.net", "Bold Commerce"},
    {"skio.com", "Skio"},
    {"paywhirl.com", "PayWhirl"},
    {"appstle.com", "Appstle Subscriptions"},
    {"seal-subscriptions.com", "Seal Subscriptions"},
    {"recurpay.com", "Recurpay"},
    # Upsell & Cross-sell
    {"cdn.rebuyengine.com", "Rebuy"},
    {"cdn.recomify.com", "Recomify"},
    {"cdn.bold.ninja", "Bold Upsell"},
    {"selleasy.com", "Selleasy"},
    {"reconvert.io", "ReConvert"},
    {"cdn.zipify.com/ocu", "Zipify OCU"},
    {"honeycomb-upsell.com", "HoneyComb"},
    {"vitals.co", "Vitals"},
    {"widgets.bundlebuilder.com", "Bundle Builder"},
    {"foxkit.app", "FoxKit"},
    {"cdn.frequently-bought-together.com", "Frequently Bought Together"},
    {"aftersell.com", "AfterSell"},
    {"cdn.pumper.app", "Pumper Bundles"},
    # Chat & Support
    {"config.gorgias.chat", "Gorgias"},
    {"code.tidio.co", "Tidio"},
    {"embed.tawk.to", "Tawk.to"},
    {"reamaze.js", "Reamaze"},
    {"cdn.livechatinc.com", "LiveChat"},
    {"cdn.chatbot.com", "ChatBot"},
    # Shipping & Returns
    {"loopreturns.com", "Loop Returns"},
    {"returnly.com", "Returnly"},
    {"cdn.returngo.ai", "ReturnGO"},
    {"app.aftership.com", "AfterShip"},
    {"cdn.parcelpanel.com", "Parcel Panel"},
    {"track123.com", "Track123"},
    {"cdn.17track.net", "17TRACK"},
    {"trackingmore-service.com", "TrackingMore"},
    {"cdn.route.com", "Route"},
    {"shippingchimp.com", "ShippingChimp"},
    {"tracktor.app", "Tracktor"},
    # Payment / BNPL
    {"static.afterpay.com", "Afterpay"},
    {"afterpay.com/afterpay.js", "Afterpay"},
    {"js.klarna.com", "Klarna"},
    {"klarnaservices.com", "Klarna"},
    {"widget.sezzle.com", "Sezzle"},
    {"cdn.shoppay.io", "Shop Pay"},
    {"sdk.affirm.com", "Affirm"},
    # Wishlist & Back in Stock
    {"swymrelay.com", "Wishlist Plus"},
    {"swym.it", "Wishlist Plus"},
    {"cdn.back-in-stock.com", "Back in Stock"},
    {"notifyapp.io", "Notify! Back in Stock"},
    {"cdn.yanet.me", "Yanet Back in Stock"},
    # SEO
    {"cdn.boostcommerce.net", "Boost Product Filter"},
    {"searchspring.net", "Searchspring"},
    {"searchanise.com", "Searchanise"},
    {"cdn.findify.io", "Findify"},
    {"instantsearchplus.com", "Fast Simon"},
    # Social Proof & Urgency
    {"cdn.fomo.com", "FOMO"},
    {"cdn.nudgify.com", "Nudgify"},
    {"provesrc.com", "ProveSource"},
    {"cdn.hextom.com", "Hextom"},
    # Accessibility & Compliance
    {"acsbapp.com", "accessiBe"},
    {"accessibilityserver.com", "accessiBe"},
    {"cdn.userway.org", "UserWay"},
    {"cdn.equalweb.com", "EqualWeb"},
    {"cdn.pandectes.io", "Pandectes GDPR"},
    {"cdn.termly.io", "Termly"},
    {"iubenda.com/cookie-solution", "iubenda"},
    {"cookie-script.com", "Cookie Script"},
    {"consent.cookiebot.com", "Cookiebot"},
    {"cdn.cookielaw.org", "OneTrust"},
    {"cdn.consentmo.com", "Consentmo GDPR"},
    {"cdn.complianz.io", "Complianz"},
    # Translation & Currency
    {"cdn.weglot.com", "Weglot"},
    {"cdn.langify-app.com", "Langify"},
    {"cdn.langshop.app", "LangShop"},
    {"cdn.transcy.io", "Transcy"},
    # Instagram & Social
    {"instafeed.nfcube.com", "Instafeed"},
    {"cdn.socialwidget.app", "Socialwidget"},
    {"cdn.elfsight.com", "Elfsight"},
    {"assets.pinterest.com/ext/shopify", "Pinterest for Shopify"},
    {"cdn.tapcart.com", "Tapcart"},
    # Affiliate
    {"cdn.uppromote.com", "UpPromote"},
    {"cdn.goaffpro.com", "GOAFFPRO"},
    {"cdn.bixgrow.com", "BixGrow"},
    {"cdn.shareasale.com", "ShareASale"},
    {"cdn.awin1.com", "Awin"},
    # Print on Demand
    {"printful.com/js", "Printful"},
    {"printify.com", "Printify"},
    {"gelato.com", "Gelato"},
    # Dropshipping
    {"dsers.com", "DSers"},
    {"cjdropshipping.com", "CJdropshipping"},
    {"autods.com", "AutoDS"},
    # Product Options
    {"cdn.customily.com", "Customily"},
    {"cdn.productcustomizer.com", "PC Product Options"},
    # Analytics & Tracking
    {"triplewhale.com", "Triple Whale"},
    {"cdn.elevar.io", "Elevar"},
    {"cdn.stape.io", "Stape"},
    {"wetracked.io", "wetracked"},
    # Size Charts
    {"cdn.kiwisizing.com", "Kiwi Size Chart"},
    # Store Locator
    {"stockist.co", "Stockist"},
    # Age Verification
    {"cdn.blockify.co", "Blockify"},
    # Landing Pages
    {"cdn.zipify.com", "Zipify"},
    # Misc
    {"geolocation-app.shopifycdn.com", "Geolocation"},
    {"cdn.tolstoy.com", "Tolstoy"},
    {"cdn.adroll.com", "AdRoll"},
    {"cdn.yieldify.com", "Yieldify"},
    {"cdn.nosto.com", "Nosto"},
    {"cdn.barilliance.com", "Barilliance"},
    {"cdn.clerk.io", "Clerk.io"},
    {"saasler.com", "Bold"},
    {"lightfunnels.com", "Lightfunnels"},
    {"cdn.spurit.com", "SpurIT"},
    {"tab-station.com", "Tabs Studio"},
    {"releasit.io", "Releasit COD Form"},
    {"cowlendar.com", "Cowlendar"},
    {"boostpageoptimizer.com", "Booster"},
    {"cdn.discountninja.io", "Discount Ninja"},
  ]

  defp detect_shopify_apps(acc, html) do
    found = @shopify_domains
    |> Enum.reduce(acc, fn {domain, name}, a ->
      if c?(html, String.downcase(domain)), do: [name | a], else: a
    end)

    # HTML marker-based detection (for apps that inject unique classes/IDs)
    found
    |> add(c?(html, "jdgm-widget") || c?(html, "jdgm-review"), "Judge.me")
    |> add(c?(html, "class=\"yotpo\"") || c?(html, "yotpo-main-widget"), "Yotpo Reviews")
    |> add(c?(html, "pf-element") || c?(html, "data-pf-"), "PageFly")
    |> add(c?(html, "shg-c") || c?(html, "shg-row"), "Shogun")
    |> add(c?(html, "gem-page") || c?(html, "gp-page"), "GemPages")
    |> add(c?(html, "shopify-payment-terms") || c?(html, "shopify-payment-button"), "Shop Pay")
    |> add(c?(html, "afterpay-placement") || c?(html, "<afterpay-placement"), "Afterpay")
    |> add(c?(html, "klarna-placement") || c?(html, "<klarna-placement"), "Klarna")
    |> add(c?(html, "sezzle-widget"), "Sezzle")
    |> add(c?(html, "smile-launcher") || c?(html, "smile-dock"), "Smile.io")
    |> add(c?(html, "loox-rating") || c?(html, "id=\"looxreviews\""), "Loox")
    |> add(c?(html, "stampedfn.init") || c?(html, "<!-- stamped"), "Stamped.io")
    |> add(c?(html, "gorgias-chat-widget"), "Gorgias")
    |> add(c?(html, "rechargewidget") || c?(html, "rc_container"), "ReCharge")
    |> add(c?(html, "ecomposer-section"), "EComposer")
    |> add(c?(html, "rebuy-widget") || c?(html, "data-rebuy"), "Rebuy")
    |> add(c?(html, "data-foxkit"), "FoxKit")
    |> add(c?(html, "class=\"vitals-"), "Vitals")
    |> add(c?(html, "data-triple-whale"), "Triple Whale")
    |> add(c?(html, "consentmo-gdpr"), "Consentmo GDPR")
    |> add(c?(html, "pandectes-consent"), "Pandectes GDPR")
    |> add(c?(html, "releasit-cod"), "Releasit COD Form")
    |> add(c?(html, "growave-") || c?(html, "data-growave"), "Growave")
    |> add(c?(html, "upcart-") || c?(html, "slide-cart"), "UpCart")
    |> add(c?(html, "data-bucks-"), "BUCKS Currency")
    |> add(c?(html, "transcy-") || c?(html, "data-transcy"), "Transcy")
    |> add(c?(html, "data-zipify"), "Zipify")
  end

  # ==========================================================================
  # WORDPRESS PLUGINS (~100) - /wp-content/plugins/{slug}/ + HTML markers
  # ==========================================================================

  @wp_slugs [
    # SEO
    {"wordpress-seo", "Yoast SEO"},
    {"seo-by-rank-math", "Rank Math"},
    {"all-in-one-seo-pack", "All in One SEO"},
    {"the-seo-framework", "The SEO Framework"},
    {"schema-and-structured-data-for-wp", "Schema Pro"},
    # Page Builders
    {"elementor", "Elementor"},
    {"js_composer", "WPBakery"},
    {"divi-builder", "Divi Builder"},
    {"beaver-builder-lite-version", "Beaver Builder"},
    {"bb-plugin", "Beaver Builder Pro"},
    {"fusion-builder", "Avada Builder"},
    {"oxygen", "Oxygen Builder"},
    {"bricks", "Bricks Builder"},
    {"generateblocks", "GenerateBlocks"},
    {"kadence-blocks", "Kadence Blocks"},
    {"stackable-ultimate-gutenberg-blocks", "Stackable"},
    {"spectra", "Spectra"},
    # Forms
    {"contact-form-7", "Contact Form 7"},
    {"wpforms-lite", "WPForms"},
    {"wpforms", "WPForms Pro"},
    {"gravityforms", "Gravity Forms"},
    {"formidable", "Formidable Forms"},
    {"ninja-forms", "Ninja Forms"},
    {"forminator", "Forminator"},
    {"fluentform", "Fluent Forms"},
    {"everest-forms", "Everest Forms"},
    # Ecommerce
    {"woocommerce", "WooCommerce"},
    {"easy-digital-downloads", "Easy Digital Downloads"},
    {"woo-gutenberg-products-block", "WooCommerce Blocks"},
    {"woocommerce-payments", "WooCommerce Payments"},
    {"woo-stripe-payment", "WooCommerce Stripe"},
    {"checkout-for-woocommerce", "CheckoutWC"},
    {"woocommerce-subscriptions", "WooCommerce Subscriptions"},
    {"woocommerce-memberships", "WooCommerce Memberships"},
    {"woocommerce-bookings", "WooCommerce Bookings"},
    # Analytics
    {"google-analytics-for-wordpress", "MonsterInsights"},
    {"google-site-kit", "Google Site Kit"},
    {"matomo", "Matomo Analytics"},
    {"pixelyoursite", "PixelYourSite"},
    {"independent-analytics", "Independent Analytics"},
    # Caching & Performance
    {"wp-rocket", "WP Rocket"},
    {"w3-total-cache", "W3 Total Cache"},
    {"litespeed-cache", "LiteSpeed Cache"},
    {"wp-super-cache", "WP Super Cache"},
    {"autoptimize", "Autoptimize"},
    {"wp-fastest-cache", "WP Fastest Cache"},
    {"cache-enabler", "Cache Enabler"},
    {"sg-cachepress", "SG Optimizer"},
    {"breeze", "Breeze"},
    {"nitropack", "NitroPack"},
    {"perfmatters", "Perfmatters"},
    {"flying-press", "FlyingPress"},
    # Image Optimization
    {"wp-smushit", "Smush"},
    {"shortpixel-image-optimiser", "ShortPixel"},
    {"imagify", "Imagify"},
    {"ewww-image-optimizer", "EWWW Optimizer"},
    {"optimole-wp", "Optimole"},
    {"webp-converter-for-media", "WebP Converter"},
    # Security
    {"wordfence", "Wordfence"},
    {"sucuri-scanner", "Sucuri Security"},
    {"really-simple-ssl", "Really Simple SSL"},
    {"all-in-one-wp-security-and-firewall", "AIOS Security"},
    {"limit-login-attempts-reloaded", "Limit Login Attempts"},
    {"jetpack", "Jetpack"},
    # Multilingual
    {"sitepress-multilingual-cms", "WPML"},
    {"polylang", "Polylang"},
    {"translatepress-multilingual", "TranslatePress"},
    {"weglot", "Weglot"},
    # Marketing & Email
    {"mailchimp-for-wp", "MC4WP Mailchimp"},
    {"mailchimp-for-woocommerce", "Mailchimp WooCommerce"},
    {"mailpoet", "MailPoet"},
    {"leadin", "HubSpot"},
    {"convertkit", "ConvertKit"},
    {"optinmonster", "OptinMonster"},
    {"sumo", "Sumo"},
    # Sliders & Media
    {"revslider", "Slider Revolution"},
    {"ml-slider", "MetaSlider"},
    {"smart-slider-3", "Smart Slider 3"},
    {"envira-gallery-lite", "Envira Gallery"},
    {"modula-best-grid-gallery", "Modula Gallery"},
    {"nextgen-gallery", "NextGEN Gallery"},
    # Social
    {"social-warfare", "Social Warfare"},
    {"add-to-any", "AddToAny Share"},
    {"instagram-feed", "Smash Balloon Instagram"},
    {"custom-facebook-feed", "Smash Balloon Facebook"},
    {"feeds-for-youtube", "Smash Balloon YouTube"},
    # Tables & Content
    {"tablepress", "TablePress"},
    {"wp-pagenavi", "WP-PageNavi"},
    {"advanced-custom-fields", "ACF"},
    {"advanced-custom-fields-pro", "ACF Pro"},
    # LMS & Membership
    {"sfwd-lms", "LearnDash"},
    {"lifterlms", "LifterLMS"},
    {"memberpress", "MemberPress"},
    {"restrict-content-pro", "Restrict Content Pro"},
    {"tutor", "Tutor LMS"},
    {"sensei-lms", "Sensei LMS"},
    {"paid-memberships-pro", "Paid Memberships Pro"},
    # Community
    {"buddypress", "BuddyPress"},
    {"bbpress", "bbPress"},
    # Backup & Migration
    {"updraftplus", "UpdraftPlus"},
    {"backwpup", "BackWPup"},
    {"duplicator", "Duplicator"},
    {"all-in-one-wp-migration", "All-in-One WP Migration"},
    # GDPR & Cookies
    {"cookie-notice", "Cookie Notice"},
    {"cookie-law-info", "CookieYes"},
    {"complianz-gdpr", "Complianz"},
    {"gdpr-cookie-compliance", "GDPR Cookie Compliance"},
    {"iubenda-cookie-law-solution", "iubenda"},
    # Misc
    {"akismet", "Akismet"},
    {"amp", "AMP"},
    {"wp-mail-smtp", "WP Mail SMTP"},
    {"header-footer-code-manager", "Header Footer Code Manager"},
    {"code-snippets", "Code Snippets"},
    {"redirection", "Redirection"},
    {"wordpress-popup", "Hustle"},
    {"classic-editor", "Classic Editor"},
  ]

  defp detect_wp_plugins(acc, html) do
    found = @wp_slugs
    |> Enum.reduce(acc, fn {slug, name}, a ->
      if c?(html, "/wp-content/plugins/#{slug}/"), do: [name | a], else: a
    end)

    # HTML comment/class-based detection
    found
    |> add(c?(html, "<!-- this site is optimized") && c?(html, "yoast"), "Yoast SEO")
    |> add(c?(html, "<!-- rank math seo"), "Rank Math")
    |> add(c?(html, "<!-- all in one seo"), "All in One SEO")
    |> add(c?(html, "is like a rocket") && c?(html, "wp rocket"), "WP Rocket")
    |> add(c?(html, "performance optimized by w3 total cache"), "W3 Total Cache")
    |> add(c?(html, "page generated by litespeed"), "LiteSpeed Cache")
    |> add(c?(html, "cached page generated by wp-super-cache"), "WP Super Cache")
    |> add(c?(html, "<!-- autoptimize"), "Autoptimize")
    |> add(c?(html, "class=\"wpcf7\"") || c?(html, "wpcf7-form"), "Contact Form 7")
    |> add(c?(html, "wpforms-container"), "WPForms")
    |> add(c?(html, "gform_wrapper"), "Gravity Forms")
    |> add(c?(html, "class=\"mc4wp-form\""), "MC4WP Mailchimp")
    |> add(c?(html, "class=\"tablepress\""), "TablePress")
    |> add(c?(html, "wp-pagenavi"), "WP-PageNavi")
    |> add(c?(html, "rs-module-wrap") || c?(html, "class=\"rev_slider"), "Slider Revolution")
    |> add(c?(html, "class=\"metaslider\""), "MetaSlider")
    |> add(c?(html, "cookie-notice-container") || c?(html, "id=\"cookie-notice\""), "Cookie Notice")
    |> add(c?(html, "id=\"cky-consent\"") || c?(html, "cky-consent-bar"), "CookieYes")
    |> add(c?(html, "<!-- complianz") || c?(html, "class=\"cmplz-"), "Complianz")
    |> add(c?(html, "buddypress") && c?(html, "class=\"bp-"), "BuddyPress")
    |> add(c?(html, "bbpress-forums"), "bbPress")
    |> add(c?(html, "learndash-wrapper") || c?(html, "sfwd-"), "LearnDash")
    |> add(c?(html, "class=\"llms-"), "LifterLMS")
    |> add(c?(html, "wpml-ls-"), "WPML")
  end

  # ==========================================================================
  # PAGE BUILDERS - detected as apps, not tech (regardless of platform)
  # ==========================================================================

  # == Helpers ==
  defp c?(s, p), do: String.contains?(s, p)
  defp add(a, true, n), do: [n | a]
  defp add(a, false, _), do: a
  defp add(a, nil, _), do: a
end
