defmodule LS.HTTP.ClassificationTest do
  use ExUnit.Case, async: true

  alias LS.HTTP.{TextExtractor, SchemaExtractor, BusinessClassifier}

  @empty_signals %{
    http_tech: "", http_apps: "", http_title: "", http_meta_description: "",
    http_pages: "", http_schema_type: "", http_og_type: "", ctl_tld: "",
    dns_txt: "", h1: "", body_text: "", nav_links: ""
  }

  defp classify(overrides), do: BusinessClassifier.classify(Map.merge(@empty_signals, overrides))

  # ==========================================================================
  # TextExtractor
  # ==========================================================================

  describe "TextExtractor.extract_h1/1" do
    test "extracts simple h1" do
      assert TextExtractor.extract_h1("<h1>Hello World</h1>") == "Hello World"
    end

    test "strips inner tags" do
      assert TextExtractor.extract_h1("<h1><span>Bold</span> text</h1>") == "Bold text"
    end

    test "returns empty for nil" do
      assert TextExtractor.extract_h1(nil) == ""
    end

    test "returns empty when no h1" do
      assert TextExtractor.extract_h1("<h2>Not h1</h2>") == ""
    end

    test "truncates at 200 chars" do
      long = String.duplicate("a", 300)
      result = TextExtractor.extract_h1("<h1>#{long}</h1>")
      assert String.length(result) <= 200
    end
  end

  describe "TextExtractor.extract_nav_links/1" do
    test "extracts links from nav" do
      html = ~s(<nav><a href="/">Home</a><a href="/about">About</a></nav>)
      assert TextExtractor.extract_nav_links(html) == "Home About"
    end

    test "falls back to header" do
      html = ~s(<header><a href="/">Home</a><a href="/contact">Contact</a></header>)
      assert TextExtractor.extract_nav_links(html) == "Home Contact"
    end

    test "returns empty for nil" do
      assert TextExtractor.extract_nav_links(nil) == ""
    end

    test "returns empty when no nav or header" do
      assert TextExtractor.extract_nav_links("<div><a href='/'>Link</a></div>") == ""
    end
  end

  describe "TextExtractor.extract_visible_text/2" do
    test "strips scripts and styles" do
      html = "<script>var x=1;</script><style>.a{}</style><p>Hello</p>"
      assert TextExtractor.extract_visible_text(html, 500) =~ "Hello"
      refute TextExtractor.extract_visible_text(html, 500) =~ "var x"
    end

    test "strips HTML tags" do
      assert TextExtractor.extract_visible_text("<div><p>Text</p></div>", 500) =~ "Text"
    end

    test "returns empty for nil" do
      assert TextExtractor.extract_visible_text(nil) == ""
    end

    test "respects max_chars" do
      html = "<p>#{String.duplicate("word ", 200)}</p>"
      result = TextExtractor.extract_visible_text(html, 50)
      assert String.length(result) <= 50
    end
  end

  # ==========================================================================
  # SchemaExtractor
  # ==========================================================================

  describe "SchemaExtractor.extract_schema_type/1" do
    test "extracts simple type" do
      html = ~s(<script type="application/ld+json">{"@type": "Restaurant"}</script>)
      assert SchemaExtractor.extract_schema_type(html) == "Restaurant"
    end

    test "picks most specific type" do
      html = ~s(<script type="application/ld+json">{"@type": "Organization"}</script>
               <script type="application/ld+json">{"@type": "Dentist"}</script>)
      assert SchemaExtractor.extract_schema_type(html) == "Dentist"
    end

    test "handles @graph" do
      html = ~s(<script type="application/ld+json">{"@graph": [{"@type": "WebSite"}, {"@type": "SoftwareApplication"}]}</script>)
      assert SchemaExtractor.extract_schema_type(html) == "SoftwareApplication"
    end

    test "returns empty for nil" do
      assert SchemaExtractor.extract_schema_type(nil) == ""
    end

    test "returns empty for no JSON-LD" do
      assert SchemaExtractor.extract_schema_type("<html><body>Hello</body></html>") == ""
    end

    test "handles invalid JSON" do
      html = ~s(<script type="application/ld+json">{invalid}</script>)
      assert SchemaExtractor.extract_schema_type(html) == ""
    end
  end

  describe "SchemaExtractor.extract_og_type/1" do
    test "extracts og:type property-first" do
      html = ~s(<meta property="og:type" content="product"/>)
      assert SchemaExtractor.extract_og_type(html) == "product"
    end

    test "extracts og:type content-first" do
      html = ~s(<meta content="article" property="og:type"/>)
      assert SchemaExtractor.extract_og_type(html) == "article"
    end

    test "returns lowercase" do
      html = ~s(<meta property="og:type" content="Product"/>)
      assert SchemaExtractor.extract_og_type(html) == "product"
    end

    test "returns empty for nil" do
      assert SchemaExtractor.extract_og_type(nil) == ""
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 1: Tech stack
  # ==========================================================================

  describe "Layer 1 — Tech stack" do
    test "Shopify → Ecommerce" do
      r = classify(%{http_tech: "Shopify|React|Cloudflare"})
      assert r.business_model == "Ecommerce"
    end

    test "WooCommerce → Ecommerce" do
      r = classify(%{http_tech: "WordPress|WooCommerce"})
      assert r.business_model == "Ecommerce"
    end

    test "Magento → Ecommerce" do
      r = classify(%{http_tech: "Magento|PHP"})
      assert r.business_model == "Ecommerce"
    end

    test "BigCommerce → Ecommerce" do
      r = classify(%{http_tech: "BigCommerce"})
      assert r.business_model == "Ecommerce"
    end

    test "Substack → Newsletter" do
      r = classify(%{http_tech: "Substack"})
      assert r.business_model == "Newsletter"
    end

    test "Ghost → Media" do
      r = classify(%{http_tech: "Ghost"})
      assert r.business_model == "Media"
    end

    test "Discourse → Community" do
      r = classify(%{http_tech: "Discourse"})
      assert r.business_model == "Community"
    end

    test "Shopify ecommerce apps boost" do
      r = classify(%{http_tech: "Shopify", http_apps: "Klaviyo|Judge.me|Afterpay"})
      assert r.business_model == "Ecommerce"
      assert r.confidence >= 0.7
    end

    test "WordPress LMS plugins → Education" do
      r = classify(%{http_tech: "WordPress", http_apps: "LearnDash"})
      assert r.business_model == "Education"
    end

    test "WordPress community plugins → Community" do
      r = classify(%{http_tech: "WordPress", http_apps: "BuddyPress"})
      assert r.business_model == "Community"
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 2: Schema.org
  # ==========================================================================

  describe "Layer 2 — Schema.org types" do
    test "SoftwareApplication → SaaS" do
      r = classify(%{http_schema_type: "SoftwareApplication"})
      assert r.business_model == "SaaS"
    end

    test "Product → Ecommerce" do
      r = classify(%{http_schema_type: "Product"})
      assert r.business_model == "Ecommerce"
    end

    test "Restaurant → Food & Beverage" do
      r = classify(%{http_schema_type: "Restaurant"})
      assert r.industry == "Food & Beverage"
    end

    test "Dentist → Healthcare" do
      r = classify(%{http_schema_type: "Dentist"})
      assert r.industry == "Healthcare"
    end

    test "LegalService → Legal" do
      r = classify(%{http_schema_type: "LegalService"})
      assert r.business_model == "Consulting"
      assert r.industry == "Legal"
    end

    test "ClothingStore → Ecommerce + Fashion" do
      r = classify(%{http_schema_type: "ClothingStore"})
      assert r.business_model == "Ecommerce"
      assert r.industry == "Fashion"
    end

    test "FurnitureStore → Ecommerce + Home & Garden" do
      r = classify(%{http_schema_type: "FurnitureStore"})
      assert r.business_model == "Ecommerce"
      assert r.industry == "Home & Garden"
    end

    test "CollegeOrUniversity → Education" do
      r = classify(%{http_schema_type: "CollegeOrUniversity"})
      assert r.business_model == "Education"
      assert r.industry == "Education"
    end

    test "og:type product → Ecommerce boost" do
      r = classify(%{http_og_type: "product"})
      assert r.business_model == "Ecommerce"
    end

    test "og:type article → Media boost" do
      r = classify(%{http_og_type: "article"})
      assert r.business_model == "Media"
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 3: Page structure
  # ==========================================================================

  describe "Layer 3 — Page structure" do
    test "pricing + login + docs = SaaS (triple)" do
      r = classify(%{http_pages: "/pricing|/login|/docs"})
      assert r.business_model == "SaaS"
    end

    test "pricing + login = likely SaaS" do
      r = classify(%{http_pages: "/pricing|/login"})
      assert r.business_model == "SaaS"
    end

    test "pricing + free-trial = SaaS" do
      r = classify(%{http_pages: "/pricing|/free-trial"})
      assert r.business_model == "SaaS"
    end

    test "cart = Ecommerce" do
      r = classify(%{http_pages: "/cart|/products|/about"})
      assert r.business_model == "Ecommerce"
    end

    test "portfolio + case-studies = Agency" do
      r = classify(%{http_pages: "/portfolio|/case-studies|/about"})
      assert r.business_model == "Agency"
    end

    test "courses + enroll = Education" do
      r = classify(%{http_pages: "/courses|/enroll|/about"})
      assert r.business_model == "Education"
    end

    test "directory + submit = Directory" do
      r = classify(%{http_pages: "/directory|/submit-listing"})
      assert r.business_model == "Directory"
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 4: Nav links
  # ==========================================================================

  describe "Layer 4 — Nav links" do
    test "Shop Products → Ecommerce" do
      r = classify(%{nav_links: "Shop Products Collections Sale"})
      assert r.business_model == "Ecommerce"
    end

    test "Pricing Docs Login → SaaS" do
      r = classify(%{nav_links: "Pricing Docs API Login"})
      assert r.business_model == "SaaS"
    end

    test "Portfolio Case Studies → Agency" do
      r = classify(%{nav_links: "Portfolio Our Work Case Studies About"})
      assert r.business_model == "Agency"
    end

    test "Our Menu Reservations → Food & Beverage industry" do
      r = classify(%{nav_links: "Our Menu Reservations About Contact"})
      assert r.industry == "Food & Beverage"
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 5: TLD
  # ==========================================================================

  describe "Layer 5 — TLD" do
    test ".edu → Education" do
      r = classify(%{ctl_tld: "edu"})
      assert r.industry == "Education"
    end

    test ".law → Legal" do
      r = classify(%{ctl_tld: "law"})
      assert r.industry == "Legal"
    end

    test ".dental → Healthcare" do
      r = classify(%{ctl_tld: "dental"})
      assert r.industry == "Healthcare"
    end

    test ".bank → Fintech" do
      r = classify(%{ctl_tld: "bank"})
      assert r.industry == "Fintech"
    end

    test ".restaurant → Food & Beverage" do
      r = classify(%{ctl_tld: "restaurant"})
      assert r.industry == "Food & Beverage"
    end

    test ".ai → AI & ML" do
      r = classify(%{ctl_tld: "ai"})
      assert r.industry == "AI & ML"
    end

    test ".travel → Travel" do
      r = classify(%{ctl_tld: "travel"})
      assert r.industry == "Travel"
    end

    test ".construction → Construction & Manufacturing" do
      r = classify(%{ctl_tld: "construction"})
      assert r.industry == "Construction & Manufacturing"
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 6: Keywords
  # ==========================================================================

  describe "Layer 6 — Keywords (business model)" do
    test "SaaS keywords in title" do
      r = classify(%{http_title: "Cloud-based Project Management SaaS"})
      assert r.business_model == "SaaS"
    end

    test "Ecommerce keywords in title" do
      r = classify(%{http_title: "Shop Now - Free Shipping on Orders"})
      assert r.business_model == "Ecommerce"
    end

    test "Agency keywords in title" do
      r = classify(%{http_title: "Full-Service Digital Agency"})
      assert r.business_model == "Agency"
    end

    test "Newsletter keywords" do
      r = classify(%{http_title: "Tech Newsletter - Weekly Digest"})
      assert r.business_model == "Newsletter"
    end

    test "Marketplace keywords" do
      r = classify(%{http_title: "The #1 Marketplace to Buy and Sell"})
      assert r.business_model == "Marketplace"
    end

    test "body text gets half points" do
      # Title keyword = full points
      r_title = classify(%{http_title: "Cloud-based SaaS Platform"})
      # Body keyword = half points
      r_body = classify(%{body_text: "cloud-based saas platform for teams"})
      assert r_title.confidence >= r_body.confidence
    end
  end

  describe "Layer 6 — Keywords (industry)" do
    test "Fintech keywords" do
      r = classify(%{http_title: "Fintech Payment Gateway Platform"})
      assert r.industry == "Fintech"
    end

    test "Healthcare keywords" do
      r = classify(%{http_title: "HIPAA-Compliant Telemedicine Platform"})
      assert r.industry == "Healthcare"
    end

    test "Marketing keywords" do
      r = classify(%{http_title: "SEO and PPC Marketing Platform"})
      assert r.industry == "Marketing"
    end

    test "Legal keywords" do
      r = classify(%{http_title: "Personal Injury Law Firm"})
      assert r.industry == "Legal"
    end

    test "Real Estate keywords" do
      r = classify(%{http_title: "Homes for Sale - MLS Real Estate"})
      assert r.industry == "Real Estate"
    end

    test "AI & ML keywords" do
      r = classify(%{http_title: "AI-Powered LLM Platform for Enterprise"})
      assert r.industry == "AI & ML"
    end

    test "DevTools keywords" do
      r = classify(%{http_title: "Developer Platform - SDK & API Tools"})
      assert r.industry == "DevTools"
    end

    test "Beauty keywords" do
      r = classify(%{http_title: "Skincare & Cosmetics Beauty Products"})
      assert r.industry == "Beauty"
    end

    test "body text catches industry that title misses" do
      r = classify(%{http_title: "Our Products", body_text: "skincare serum moisturizer beauty"})
      assert r.industry == "Beauty"
    end
  end

  # ==========================================================================
  # BusinessClassifier — Layer 7: DNS TXT
  # ==========================================================================

  describe "Layer 7 — DNS TXT" do
    test "Shopify verification boosts Ecommerce" do
      # DNS alone is weak (2 pts), but combined with other signals it contributes
      r_without = classify(%{http_title: "Our Store - Shop Now"})
      r_with = classify(%{http_title: "Our Store - Shop Now", dns_txt: "shopify-verification=abc123"})
      assert r_with.business_model == "Ecommerce"
      assert r_with.confidence >= r_without.confidence
    end
  end

  # ==========================================================================
  # Combined realistic scenarios
  # ==========================================================================

  describe "combined realistic scenarios" do
    test "Shopify skincare store" do
      r = classify(%{
        http_tech: "Shopify|React",
        http_apps: "Klaviyo|Judge.me",
        http_title: "Glow Skincare - Natural Beauty Products",
        http_pages: "/collections|/cart|/products",
        body_text: "shop our collection of skincare serums and moisturizers"
      })
      assert r.business_model == "Ecommerce"
      assert r.industry == "Beauty"
      assert r.confidence >= 0.7
    end

    test "B2B SaaS HR platform" do
      r = classify(%{
        http_title: "HR Software - Recruiting & Payroll Platform",
        http_pages: "/pricing|/login|/docs|/api",
        http_schema_type: "SoftwareApplication",
        h1: "All-in-one HR platform",
        body_text: "applicant tracking onboarding payroll per seat billed annually"
      })
      assert r.business_model == "SaaS"
      assert r.industry == "HR & Recruiting"
      assert r.confidence >= 0.8
    end

    test "law firm" do
      r = classify(%{
        http_schema_type: "LegalService",
        http_title: "Smith & Associates - Personal Injury Law Firm",
        ctl_tld: "law",
        nav_links: "Practice Areas Attorneys About Contact",
        body_text: "litigation personal injury attorneys at law"
      })
      assert r.business_model == "Consulting"
      assert r.industry == "Legal"
      assert r.confidence >= 0.8
    end

    test "fintech newsletter" do
      r = classify(%{
        http_tech: "Substack",
        http_title: "Fintech Weekly - Banking & Crypto Newsletter",
        body_text: "subscribe to our weekly digest on fintech payment trends"
      })
      assert r.business_model == "Newsletter"
      assert r.industry == "Fintech"
    end

    test "marketing agency" do
      r = classify(%{
        http_title: "Creative Digital Agency - SEO & PPC Services",
        http_pages: "/portfolio|/case-studies|/services",
        nav_links: "Portfolio Our Work Services About Contact",
        body_text: "we help brands grow with seo ppc and email marketing lead gen"
      })
      assert r.business_model == "Agency"
      assert r.industry == "Marketing"
    end

    test "AI SaaS" do
      r = classify(%{
        http_title: "AI-Powered Data Analytics Platform",
        http_schema_type: "SoftwareApplication",
        http_pages: "/pricing|/login|/docs",
        body_text: "machine learning llm generative ai cloud-based per user"
      })
      assert r.business_model == "SaaS"
      assert r.industry == "AI & ML"
      assert r.confidence >= 0.8
    end

    test "furniture ecommerce" do
      r = classify(%{
        http_schema_type: "FurnitureStore",
        http_tech: "Shopify",
        http_title: "Modern Home Furniture & Decor",
        http_pages: "/collections|/cart",
        body_text: "furniture interior design home decor free shipping"
      })
      assert r.business_model == "Ecommerce"
      assert r.industry == "Home & Garden"
    end

    test "university" do
      r = classify(%{
        http_schema_type: "CollegeOrUniversity",
        ctl_tld: "edu",
        http_title: "State University - Academic Programs",
        http_pages: "/courses|/admissions|/campus",
        body_text: "academic curriculum student enrollment online learning"
      })
      assert r.business_model == "Education"
      assert r.industry == "Education"
      assert r.confidence >= 0.8
    end
  end

  # ==========================================================================
  # Edge cases
  # ==========================================================================

  describe "edge cases" do
    test "empty signals → empty result" do
      r = BusinessClassifier.classify(@empty_signals)
      assert r.business_model == ""
      assert r.industry == ""
      assert r.confidence == 0.0
    end

    test "nil input → empty result" do
      r = BusinessClassifier.classify(nil)
      assert r == %{business_model: "", industry: "", confidence: 0.0, method: ""}
    end

    test "non-map input → empty result" do
      r = BusinessClassifier.classify("not a map")
      assert r == %{business_model: "", industry: "", confidence: 0.0, method: ""}
    end

    test "confidence is between 0 and 1" do
      r = classify(%{
        http_tech: "Shopify", http_apps: "Klaviyo|Judge.me|Afterpay",
        http_title: "Shop Now - Free Shipping",
        http_pages: "/cart|/collections", http_og_type: "product"
      })
      assert r.confidence >= 0.0
      assert r.confidence <= 1.0
    end

    test "confidence never exceeds 0.99" do
      r = classify(%{
        http_tech: "Shopify", http_apps: "Klaviyo|Judge.me|Afterpay|Klarna|Smile.io",
        http_schema_type: "Product", http_og_type: "product",
        http_title: "Shop Now - Buy Now - Add to Cart - Free Shipping",
        http_pages: "/cart|/checkout|/collections|/products",
        nav_links: "Shop Products Collections Sale",
        body_text: "shop now buy now add to cart free shipping our collection",
        dns_txt: "shopify-verification=abc"
      })
      assert r.confidence <= 0.99
    end

    test "signals with nil values in map" do
      r = BusinessClassifier.classify(%{
        http_tech: nil, http_apps: nil, http_title: nil,
        http_meta_description: nil, http_pages: nil,
        http_schema_type: nil, http_og_type: nil,
        ctl_tld: nil, dns_txt: nil, h1: nil,
        body_text: nil, nav_links: nil
      })
      assert r.business_model == ""
      assert r.confidence == 0.0
    end

    test "method field tracks which layers contributed" do
      r = classify(%{http_tech: "Shopify", http_pages: "/cart|/checkout"})
      assert r.method =~ "tech"
      assert r.method =~ "pages"
    end
  end
end
