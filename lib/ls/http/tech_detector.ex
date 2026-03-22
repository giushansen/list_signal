defmodule LS.HTTP.TechDetector do
  @moduledoc "Zero-false-positive technology detection from HTML and headers."

  def detect(response) do
    body = safe_body(response.body)
    headers = response[:headers] || []
    srcs = extract_attr(body, ~r/<script[^>]*\bsrc\s*=\s*["']([^"']+)["']/is)
    hrefs = extract_attr(body, ~r/<link[^>]*\bhref\s*=\s*["']([^"']+)["']/is)
    metas = extract_all(body, ~r/<meta\s[^>]*>/is)
    inline = extract_inline_scripts(body)
    html = String.downcase(body)
    urls = srcs ++ hrefs
    tech = []
      |> from_headers(headers)
      |> from_srcs(srcs)
      |> from_hrefs(hrefs)
      |> from_meta(metas)
      |> from_inline(inline)
      |> from_html(html)
      |> from_urls(urls)
      |> Enum.uniq() |> Enum.sort()
    %{tech: tech, cdn: detect_cdn(headers), is_js_site: js_site?(html)}
  end

  defp from_headers(a, hdrs) do
    h = hmap(hdrs)
    a
    |> add(h["server"] =~ ~r/\bnginx\b/i, "Nginx")
    |> add(h["server"] =~ ~r/\bapache\b/i, "Apache")
    |> add(h["server"] =~ ~r/\bcloudflare\b/i, "Cloudflare")
    |> add(h["server"] =~ ~r/\bvercel\b/i, "Vercel")
    |> add(h["server"] =~ ~r/\bnetlify\b/i, "Netlify")
    |> add(h["server"] =~ ~r/\bakamaighost\b/i, "Akamai")
    |> add(h["server"] =~ ~r/\bcowboy\b/i, "Cowboy")
    |> add(h["server"] =~ ~r/\bgunicorn\b/i, "Gunicorn")
    |> add(h["server"] =~ ~r/\bopenresty\b/i, "OpenResty")
    |> add(h["server"] =~ ~r/\bcaddy\b/i, "Caddy")
    |> add(h["server"] =~ ~r/\blitespeed\b/i, "LiteSpeed")
    |> add(h["server"] =~ ~r/\benvoy\b/i, "Envoy")
    |> add(h["server"] =~ ~r/\biis\b/i, "IIS")
    |> add(h["server"] =~ ~r/\bpepyaka\b/i, "Wix")
    |> add(h["server"] =~ ~r/\bdeno\b/i, "Deno")
    |> add(Map.has_key?(h, "cf-ray"), "Cloudflare")
    |> add(Map.has_key?(h, "x-vercel-id"), "Vercel")
    |> add(Map.has_key?(h, "x-nf-request-id"), "Netlify")
    |> add(Map.has_key?(h, "x-amz-cf-id") || Map.has_key?(h, "x-amz-cf-pop"), "CloudFront")
    |> add(Map.has_key?(h, "x-fastly-request-id") || h["x-served-by"] =~ ~r/^cache-/i, "Fastly")
    |> add(Map.has_key?(h, "x-akamai-transformed"), "Akamai")
    |> add(Map.has_key?(h, "x-shopid"), "Shopify")
    |> add(Map.has_key?(h, "x-magento-vary"), "Magento")
    |> add(Map.has_key?(h, "x-drupal-cache") || Map.has_key?(h, "x-drupal-dynamic-cache"), "Drupal")
    |> add(Map.has_key?(h, "x-wix-request-id"), "Wix")
    |> add(Map.has_key?(h, "x-render-origin-server"), "Render")
    |> add(Map.has_key?(h, "x-litespeed-cache"), "LiteSpeed Cache")
    |> add(Map.has_key?(h, "x-sucuri-id"), "Sucuri")
    |> add(h["x-powered-by"] =~ ~r/\bnext\.?js\b/i, "Next.js")
    |> add(h["x-powered-by"] =~ ~r/\bexpress\b/i, "Express")
    |> add(h["x-powered-by"] =~ ~r/\bphp\b/i, "PHP")
    |> add(h["x-powered-by"] =~ ~r/\basp\.net\b/i, "ASP.NET")
    |> add(h["x-powered-by"] =~ ~r/w3 total cache/i, "W3 Total Cache")
    |> add(h["x-powered-by"] =~ ~r/\bcraftcms\b/i, "Craft CMS")
  end

  defp from_srcs(a, s) do
    a
    |> add(m?(s, "googletagmanager.com/gtag/js"), "Google Analytics")
    |> add(m?(s, "googletagmanager.com/gtm.js"), "Google Tag Manager")
    |> add(m?(s, "connect.facebook.net") && m?(s, "fbevents"), "Meta Pixel")
    |> add(m?(s, "static.hotjar.com"), "Hotjar")
    |> add(m?(s, "cdn.segment.com/analytics"), "Segment")
    |> add(m?(s, "cdn.mxpnl.com"), "Mixpanel")
    |> add(m?(s, "js.hs-scripts.com") || m?(s, "js.hs-analytics.net"), "HubSpot")
    |> add(m?(s, "widget.intercom.io"), "Intercom")
    |> add(m?(s, "js.driftt.com"), "Drift")
    |> add(m?(s, "client.crisp.chat"), "Crisp")
    |> add(m?(s, "static.zdassets.com"), "Zendesk")
    |> add(m?(s, "cdn.amplitude.com"), "Amplitude")
    |> add(m?(s, "cdn.heapanalytics.com"), "Heap")
    |> add(m?(s, "posthog.com"), "PostHog")
    |> add(m?(s, "plausible.io/js/"), "Plausible")
    |> add(m?(s, "clarity.ms/tag/"), "Microsoft Clarity")
    |> add(m?(s, "cdn.mouseflow.com"), "Mouseflow")
    |> add(m?(s, "cdn.luckyorange.com"), "Lucky Orange")
    |> add(m?(s, "snap.licdn.com"), "LinkedIn Insight")
    |> add(m?(s, "s.pinimg.com/ct/"), "Pinterest Tag")
    |> add(m?(s, "analytics.tiktok.com"), "TikTok Pixel")
    |> add(m?(s, "sc-static.net/scevent"), "Snapchat Pixel")
    |> add(m?(s, "cdn.pendo.io"), "Pendo")
    |> add(m?(s, "fullstory.com/s/fs.js"), "FullStory")
    |> add(m?(s, "cdn.logrocket.io") || m?(s, "cdn.lr-intake.com"), "LogRocket")
    |> add(m?(s, "cdn.rollbar.com"), "Rollbar")
    |> add(m?(s, "browser.sentry-cdn.com"), "Sentry")
    |> add(m?(s, "js-agent.newrelic.com") || m?(s, "bam.nr-data.net"), "New Relic")
    |> add(m?(s, "cdn.datadog-agent.com") || m?(s, "datadoghq-browser-agent"), "Datadog")
    |> add(m?(s, "assets.adobedtm.com"), "Adobe Launch")
    |> add(m?(s, "tags.tiqcdn.com") || m?(s, "tealiumiq.com"), "Tealium")
    |> add(m?(s, "pi.pardot.com"), "Pardot")
    |> add(m?(s, "munchkin.marketo.net"), "Marketo")
    |> add(m?(s, "fast.appcues.com"), "Appcues")
    |> add(m?(s, "js.userpilot.io"), "UserPilot")
    |> add(m?(s, "cdn.walkme.com"), "WalkMe")
    |> add(m?(s, "fast.trychameleon.com"), "Chameleon")
    |> add(m?(s, "code.jquery.com/jquery") || m?(s, "ajax.googleapis.com/ajax/libs/jquery") || m?(s, "cdnjs.cloudflare.com/ajax/libs/jquery"), "jQuery")
    |> add(m?(s, "cdn.jsdelivr.net/npm/vue") || m?(s, "unpkg.com/vue") || m?(s, "cdnjs.cloudflare.com/ajax/libs/vue"), "Vue.js")
    |> add(m?(s, "unpkg.com/react") || m?(s, "cdnjs.cloudflare.com/ajax/libs/react"), "React")
    |> add(m?(s, "cdn.jsdelivr.net/npm/alpinejs") || m?(s, "unpkg.com/alpinejs"), "Alpine.js")
    |> add(m?(s, "unpkg.com/htmx.org") || m?(s, "cdn.jsdelivr.net/npm/htmx"), "htmx")
    |> add(m?(s, "cdn.jsdelivr.net/npm/bootstrap") || m?(s, "stackpath.bootstrapcdn.com/bootstrap"), "Bootstrap")
    |> add(m?(s, "cdn.tailwindcss.com"), "Tailwind CSS")
    |> add(m?(s, "cdn.jsdelivr.net/npm/swiper") || m?(s, "unpkg.com/swiper"), "Swiper")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/gsap"), "GSAP")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/font-awesome") || m?(s, "use.fontawesome.com") || m?(s, "kit.fontawesome.com"), "Font Awesome")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/animejs"), "Anime.js")
    |> add(m?(s, "unpkg.com/aos") || m?(s, "cdn.jsdelivr.net/npm/aos"), "AOS")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/Chart.js") || m?(s, "cdn.jsdelivr.net/npm/chart.js"), "Chart.js")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/d3") || m?(s, "cdn.jsdelivr.net/npm/d3"), "D3.js")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/three.js") || m?(s, "unpkg.com/three"), "Three.js")
    |> add(m?(s, "cdnjs.cloudflare.com/ajax/libs/leaflet") || m?(s, "unpkg.com/leaflet"), "Leaflet")
    |> add(m?(s, "maps.googleapis.com") || m?(s, "maps.google.com/maps"), "Google Maps")
    |> add(m?(s, "api.mapbox.com") || m?(s, "cdn.mapbox.com"), "Mapbox")
    |> add(m?(s, "cdn.shopify.com") || m?(s, "sdks.shopifycdn.com"), "Shopify")
    |> add(m?(s, "cdn.bigcommerce.com"), "BigCommerce")
    |> add(m?(s, "app.ecwid.com"), "Ecwid")
    |> add(m?(s, "cdn.lightspeedcommerce.com"), "Lightspeed")
    |> add(m?(s, "js.stripe.com/v3"), "Stripe")
    |> add(m?(s, "paypal.com/sdk/js"), "PayPal")
    |> add(m?(s, "js.braintreegateway.com"), "Braintree")
    |> add(m?(s, "js.squareup.com") || m?(s, "web.squarecdn.com"), "Square")
    |> add(m?(s, "js.klarna.com") || m?(s, "klarnaservices.com"), "Klarna")
    |> add(m?(s, "static.afterpay.com"), "Afterpay")
    |> add(m?(s, "widget.sezzle.com"), "Sezzle")
    |> add(m?(s, "sdk.affirm.com"), "Affirm")
    |> add(m?(s, "embed.tawk.to"), "Tawk.to")
    |> add(m?(s, "code.tidio.co"), "Tidio")
    |> add(m?(s, "config.gorgias.chat"), "Gorgias")
    |> add(m?(s, "wchat.freshchat.com") || m?(s, "euc-widget.freshworks.com"), "Freshworks")
    |> add(m?(s, "cdn.livechatinc.com"), "LiveChat")
    |> add(m?(s, "static.olark.com"), "Olark")
    |> add(m?(s, "beacon-v2.helpscout.net"), "Help Scout")
    |> add(m?(s, "salesiq.zoho.com") || m?(s, "salesiq.zohopublic.com"), "Zoho SalesIQ")
    |> add(m?(s, "cdn.optimizely.com"), "Optimizely")
    |> add(m?(s, "dev.visualwebsiteoptimizer.com"), "VWO")
    |> add(m?(s, "try.abtasty.com"), "AB Tasty")
    |> add(m?(s, "cdn-3.convertexperiments.com"), "Convert")
    |> add(m?(s, "chimpstatic.com") || m?(s, "list-manage.com"), "Mailchimp")
    |> add(m?(s, "static.klaviyo.com"), "Klaviyo")
    |> add(m?(s, "trackcmp.net"), "ActiveCampaign")
    |> add(m?(s, "omnisnippet1.com") || m?(s, "omnisrc.com"), "Omnisend")
    |> add(m?(s, "f.convertkit.com"), "ConvertKit")
    |> add(m?(s, "tag.getdrip.com"), "Drip")
    |> add(m?(s, "assets.customer.io"), "Customer.io")
    |> add(m?(s, "sibautomation.com") || m?(s, "cdn.brevo.com"), "Brevo")
    |> add(m?(s, "assets.mailerlite.com"), "MailerLite")
    |> add(m?(s, "cdn.sendlane.com"), "Sendlane")
    |> add(m?(s, "cdn.postscript.io"), "Postscript")
    |> add(m?(s, "cdn.attn.tv") || m?(s, "attentive.com/dtag"), "Attentive")
    |> add(m?(s, "google.com/recaptcha") || m?(s, "gstatic.com/recaptcha"), "reCAPTCHA")
    |> add(m?(s, "hcaptcha.com"), "hCaptcha")
    |> add(m?(s, "challenges.cloudflare.com/turnstile"), "Cloudflare Turnstile")
    |> add(m?(s, "consent.cookiebot.com"), "Cookiebot")
    |> add(m?(s, "cdn.cookielaw.org") || m?(s, "optanon"), "OneTrust")
    |> add(m?(s, "consent.trustarc.com"), "TrustArc")
    |> add(m?(s, "iubenda.com/cookie-solution"), "iubenda")
    |> add(m?(s, "cdn.termly.io"), "Termly")
    |> add(m?(s, "player.vimeo.com"), "Vimeo")
    |> add(m?(s, "www.youtube.com/iframe_api"), "YouTube")
    |> add(m?(s, "play.vidyard.com"), "Vidyard")
    |> add(m?(s, "fast.wistia.com"), "Wistia")
    |> add(m?(s, "assets.calendly.com"), "Calendly")
    |> add(m?(s, "embed.typeform.com"), "Typeform")
    |> add(m?(s, "js.hsforms.net"), "HubSpot Forms")
    |> add(m?(s, "assets-global.website-files.com") || m?(s, "assets.website-files.com"), "Webflow")
    |> add(m?(s, "assets.squarespace.com") || m?(s, "static1.squarespace.com"), "Squarespace")
    |> add(m?(s, "framerusercontent.com") || m?(s, "events.framer.com"), "Framer")
    |> add(m?(s, "weebly.com/js/") || m?(s, "editmysite.com"), "Weebly")
    |> add(m?(s, "img1.wsimg.com"), "GoDaddy Builder")
    |> add(m?(s, "cdn.contentful.com"), "Contentful")
    |> add(m?(s, "cdn.sanity.io"), "Sanity")
    |> add(m?(s, "prismic.io"), "Prismic")
    |> add(m?(s, "app.storyblok.com") || m?(s, "storyblok.com/js"), "Storyblok")
    |> add(m?(s, "cdn.builder.io"), "Builder.io")
    |> add(m?(s, "cdn.jsdelivr.net/algoliasearch") || m?(s, "algoliasearch-client") || m?(s, "algolianet.com") || m?(s, "algolia.net"), "Algolia")
    |> add(m?(s, "searchspring.net"), "Searchspring")
    |> add(m?(s, "searchanise.com"), "Searchanise")
    |> add(m?(s, "cdn.findify.io"), "Findify")
    |> add(m?(s, "instantsearchplus.com"), "Fast Simon")
    |> add(m?(s, "acsbapp.com") || m?(s, "accessibilityserver.com"), "accessiBe")
    |> add(m?(s, "cdn.userway.org"), "UserWay")
    |> add(m?(s, "cdn.equalweb.com"), "EqualWeb")
    |> add(m?(s, "js.pusher.com"), "Pusher")
    |> add(m?(s, "cdn.ably.io"), "Ably")
    |> add(m?(s, "cdn.weglot.com"), "Weglot")
  end

  defp from_hrefs(a, h) do
    a
    |> add(m?(h, "fonts.googleapis.com") || m?(h, "fonts.gstatic.com"), "Google Fonts")
    |> add(m?(h, "use.typekit.net"), "Adobe Fonts")
    |> add(m?(h, "/wp-content/") || m?(h, "/wp-includes/"), "WordPress")
  end

  defp from_meta(a, m) do
    j = Enum.join(m, "\n") |> String.downcase()
    a
    |> add(gen?(j, "wordpress"), "WordPress")
    |> add(gen?(j, "drupal"), "Drupal")
    |> add(gen?(j, "joomla"), "Joomla")
    |> add(gen?(j, "ghost"), "Ghost")
    |> add(gen?(j, "wix.com"), "Wix")
    |> add(gen?(j, "woocommerce"), "WooCommerce")
    |> add(gen?(j, "prestashop"), "PrestaShop")
    |> add(gen?(j, "nuxt"), "Nuxt.js")
    |> add(gen?(j, "gatsby"), "Gatsby")
    |> add(gen?(j, "hugo"), "Hugo")
    |> add(gen?(j, "jekyll"), "Jekyll")
    |> add(gen?(j, "craftcms") || gen?(j, "craft cms"), "Craft CMS")
    |> add(gen?(j, "typo3"), "TYPO3")
    |> add(gen?(j, "concrete"), "Concrete CMS")
    |> add(gen?(j, "astro"), "Astro")
    |> add(gen?(j, "hexo"), "Hexo")
    |> add(gen?(j, "pelican"), "Pelican")
    |> add(gen?(j, "11ty") || gen?(j, "eleventy"), "Eleventy")
  end

  defp from_inline(a, js) do
    l = String.downcase(js)
    a
    |> add(c?(l, "shopify.theme") || c?(l, "shopifyanalytics"), "Shopify")
    |> add(c?(l, "__next_data__"), "Next.js")
    |> add(c?(l, "__nuxt__") || c?(l, "$nuxt"), "Nuxt.js")
    |> add(c?(l, "__remix"), "Remix")
    |> add(c?(l, "___gatsby"), "Gatsby")
    |> add(c?(l, "astro-island"), "Astro")
    |> add(c?(l, "datalayer") && c?(l, "gtm"), "Google Tag Manager")
    |> add(c?(l, "fbq(") && c?(l, "init"), "Meta Pixel")
    |> add(c?(l, "_paq.push"), "Matomo")
    |> add(c?(l, "drupal") && c?(l, "settings"), "Drupal")
    |> add(c?(l, "woocommerce_params") || c?(l, "wc_add_to_cart"), "WooCommerce")
    |> add(c?(l, "x-magento-init") || c?(l, "data-mage-init"), "Magento")
    |> add(c?(l, "rechargewidget") || c?(l, "rechargepayments"), "ReCharge")
    |> add(c?(l, "_learnq") && c?(l, "klaviyo"), "Klaviyo")
    |> add(c?(l, "bubble.io"), "Bubble")
    |> add(c?(l, "notion-static.com"), "Notion")
    |> add(c?(l, "substackcdn.com") || c?(l, "substack.com"), "Substack")
  end

  defp from_html(a, h) do
    a
    |> add(c?(h, "data-reactroot") || c?(h, "data-reactid"), "React")
    |> add(Regex.match?(~r/data-v-[0-9a-f]{7,8}/, h), "Vue.js")
    |> add(Regex.match?(~r/ng-version=/, h), "Angular")
    |> add(c?(h, "ng-app") || c?(h, "ng-controller"), "AngularJS")
    |> add(Regex.match?(~r/svelte-[a-z0-9]{5,7}/, h), "Svelte")
    |> add(c?(h, "id=\"__next\""), "Next.js")
    |> add(c?(h, "id=\"__nuxt\"") || c?(h, "data-n-head"), "Nuxt.js")
    |> add(c?(h, "id=\"___gatsby\""), "Gatsby")
    |> add(c?(h, "astro-island") || c?(h, "data-astro-"), "Astro")
    |> add(c?(h, "data-wf-page") || c?(h, "data-wf-site"), "Webflow")
    |> add(c?(h, "data-squarespace"), "Squarespace")
    |> add(c?(h, "static.wixstatic.com") || c?(h, "parastorage.com"), "Wix")
    |> add(c?(h, "/wp-content/") || c?(h, "/wp-includes/"), "WordPress")
    |> add(c?(h, "cdn.shopify.com") || c?(h, "shopify-section"), "Shopify")
    |> add(c?(h, "/sites/default/files/"), "Drupal")
    |> add(c?(h, "data-mage-init") || c?(h, "x-magento-init"), "Magento")
    |> add(c?(h, "woocommerce-page") || c?(h, "wc-block"), "WooCommerce")
    |> add(Regex.match?(~r/class="[^"]*\bMui[A-Z]/, h), "Material UI")
    |> add(c?(h, "class=\"g-recaptcha\""), "reCAPTCHA")
    |> add(c?(h, "class=\"h-captcha\""), "hCaptcha")
    |> add(c?(h, "class=\"cf-turnstile\""), "Cloudflare Turnstile")
    |> add(c?(h, "cdn.bigcommerce.com"), "BigCommerce")
    |> add(c?(h, "app.ecwid.com"), "Ecwid")
    |> add(c?(h, "framerusercontent.com"), "Framer")
    |> add(c?(h, "bubble.io"), "Bubble")
    |> add(c?(h, "notion-static.com") || c?(h, "notion.site"), "Notion")
    |> add(c?(h, "substackcdn.com"), "Substack")
    |> add(c?(h, "adsbygoogle") || c?(h, "pagead2.googlesyndication"), "Google AdSense")
    |> add(c?(h, "googletag.cmd") || c?(h, "securepubads"), "Google Publisher Tag")
  end

  defp from_urls(a, u) do
    a
    |> add(m?(u, "cdn.jsdelivr.net"), "jsDelivr")
    |> add(m?(u, "cdnjs.cloudflare.com"), "cdnjs")
    |> add(m?(u, "unpkg.com"), "unpkg")
    |> add(m?(u, "cloudinary.com"), "Cloudinary")
    |> add(m?(u, "imgix.net"), "Imgix")
    |> add(m?(u, "wp-content/plugins/woocommerce"), "WooCommerce")
    |> add(m?(u, "/_next/"), "Next.js")
    |> add(m?(u, "/_nuxt/"), "Nuxt.js")
    |> add(m?(u, "/_astro/"), "Astro")
    |> add(m?(u, "firebaseapp.com") || m?(u, "firebase.google.com") || m?(u, "__/firebase/"), "Firebase")
    |> add(m?(u, "supabase.co"), "Supabase")
  end

  defp detect_cdn(hdrs) do
    h = hmap(hdrs)
    cond do
      Map.has_key?(h, "cf-ray") || h["server"] =~ ~r/\bcloudflare\b/i -> "cloudflare"
      Map.has_key?(h, "x-amz-cf-id") || Map.has_key?(h, "x-amz-cf-pop") -> "cloudfront"
      Map.has_key?(h, "x-fastly-request-id") || h["x-served-by"] =~ ~r/^cache-/ -> "fastly"
      Map.has_key?(h, "x-akamai-transformed") || h["server"] =~ ~r/akamaighost/i -> "akamai"
      Map.has_key?(h, "x-vercel-id") || h["server"] =~ ~r/\bvercel\b/i -> "vercel"
      Map.has_key?(h, "x-nf-request-id") || h["server"] =~ ~r/\bnetlify\b/i -> "netlify"
      Map.has_key?(h, "x-sucuri-id") -> "sucuri"
      true -> ""
    end
  end

  defp m?(list, pat) do
    lp = String.downcase(pat)
    Enum.any?(list, fn item -> String.contains?(String.downcase(item), lp) end)
  end

  defp c?(s, pat), do: String.contains?(s, pat)
  defp gen?(j, kw), do: String.contains?(j, "generator") && String.contains?(j, kw)
  defp add(a, true, t), do: [t | a]
  defp add(a, false, _), do: a
  defp add(a, nil, _), do: a

  defp hmap(h) when is_list(h) do
    m = Map.new(h, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    Map.merge(%{"server" => "", "x-powered-by" => "", "x-served-by" => ""}, m)
  end
  defp hmap(h) when is_map(h) do
    m = Map.new(h, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    Map.merge(%{"server" => "", "x-powered-by" => "", "x-served-by" => ""}, m)
  end
  defp hmap(_), do: %{"server" => "", "x-powered-by" => "", "x-served-by" => ""}

  defp extract_attr(b, r) do
    r |> Regex.scan(b, capture: :all_but_first) |> List.flatten()
  rescue
    _ -> []
  end

  defp extract_all(b, r) do
    r |> Regex.scan(b) |> List.flatten()
  rescue
    _ -> []
  end

  defp extract_inline_scripts(b) do
    ~r/<script(?:\s[^>]*)?>([^<]*(?:<(?!\/script>)[^<]*)*)<\/script>/is
    |> Regex.scan(b, capture: :all_but_first) |> List.flatten()
    |> Enum.reject(fn x -> String.trim(x) == "" end) |> Enum.join("\n")
  rescue
    _ -> ""
  end

  defp js_site?(h) do
    fw = c?(h, "data-reactroot") || c?(h, "data-v-") || c?(h, "ng-version") || c?(h, "__next") || c?(h, "__nuxt")
    root = c?(h, "id=\"root\"") || c?(h, "id=\"app\"") || c?(h, "id=\"__next\"")
    sc = h |> String.split("<script") |> length()
    stripped = String.replace(h, ~r/<script.*?<\/script>/s, "")
    fw || (sc >= 3 && root) || (sc >= 5 && byte_size(stripped) < 200)
  rescue
    _ -> false
  end

  defp safe_body(b) when is_binary(b) do
    case :unicode.characters_to_binary(b, :utf8, :utf8) do
      {:error, g, _} -> g
      {:incomplete, g, _} -> g
      c when is_binary(c) -> c
    end
  rescue
    _ -> ""
  end
  defp safe_body(_), do: ""
end
