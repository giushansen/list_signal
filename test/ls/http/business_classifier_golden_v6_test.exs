defmodule LS.HTTP.BusinessClassifierGoldenV6Test do
  use ExUnit.Case, async: true

  alias LS.HTTP.BusinessClassifier

  @moduledoc """
  Golden v6 (2026-10-05): 320 domains labeled from the stored page blocks.
  Production against it: Ecommerce precision 48% with 20 of 28 false
  positives carrying WooCommerce and no product count; LocalBusiness recall
  39% (plumbers, clinics, gyms filed as Consulting or nothing); Manufacturer
  recall 9%; Marketplace 3 of 22 and Tool 8 of 18 right, all from the ML
  tier under 0.7; 42 of 320 rows were not businesses and none was flagged.
  """

  defp base(over) do
    Map.merge(
      %{
        http_tech: "", http_apps: "", http_title: "", http_meta_description: "", http_pages: "",
        http_schema_type: "", http_og_type: "", ctl_tld: "com", dns_txt: "", h1: "", body_text: "",
        nav_links: "", http_status: 200, is_js_site: false, rdap_nameservers: "", http_address: "",
        http_phone: "", domain: "example.com"
      },
      over
    )
  end

  describe "WooCommerce is a hint, not a verdict" do
    test "an SAP consultancy running WooCommerce is not a shop" do
      r =
        BusinessClassifier.classify(
          base(%{
            http_tech: "WordPress|WooCommerce|Nginx",
            http_title: "SAP Consulting Mannheim & Development | cobicon",
            http_meta_description: "SAP Consulting & Development, a reliable partner for all questions relating to your SAP world",
            body_text: "SAP Consulting & Development. Level up your business. SAP BW data protection. Our consulting firm supports your SAP analytics strategy.",
            nav_links: "Services|SAP Analytics|Scorecard|Contact"
          })
        )

      refute r.business_model == "Ecommerce", inspect(r)
    end

    test "WooCommerce with a cart and new arrivals is still a shop" do
      r =
        BusinessClassifier.classify(
          base(%{
            http_tech: "WordPress|WooCommerce",
            http_title: "Next Day Paint | Trade paint delivered",
            body_text: "Shop now. Add to cart. Free delivery on orders over 50. New arrivals: masonry paints, floor paints, spray paints. Best sellers.",
            nav_links: "All brands|Shop|Basket|Checkout"
          })
        )

      assert r.business_model == "Ecommerce", inspect(r)
    end
  end

  describe "a physical business presents itself with an address, a phone and its trade" do
    test "a plumber with an address and phone is LocalBusiness, not Consulting or nothing" do
      r =
        BusinessClassifier.classify(
          base(%{
            http_title: "Plombier Gaillard : depannage, deplacement gratuit",
            body_text: "Votre artisan plombier a Gaillard. Depannage et installation 24h/24. Intervention rapide, devis gratuit. Call us today.",
            http_address: "Rue des Jardins, 74240, Gaillard, FR",
            http_phone: "+33 7 56 79 88 40",
            domain: "plombiergaillard.fr", ctl_tld: "fr"
          })
        )

      assert r.business_model == "LocalBusiness", inspect(r)
    end

    test "a remodeling contractor and a dental clinic are LocalBusiness" do
      for {title, body} <- [
            {"Forsyth Remodeling | North Georgia Home Remodeling Experts", "Transform your house. Over 20 years of experience. Licensed general contractor. Get your free estimate today. Kitchen remodeling, basement renovation."},
            {"AGDent | Clinica dental en Madrid", "Cuida tu salud bucodental con los mejores dentistas. Ortodoncia invisible, implantes dentales. Pide cita en nuestra clinica."}
          ] do
        r = BusinessClassifier.classify(base(%{http_title: title, body_text: body, http_address: "1035 Ivy Street, Cumming, GA", http_phone: "(470) 466-9191"}))
        assert r.business_model == "LocalBusiness", inspect({title, r})
      end
    end

    test "an address and phone alone do not decide: a SaaS with a footer address stays SaaS" do
      r =
        BusinessClassifier.classify(
          base(%{
            http_title: "Tripleseat | All-in-One Event Venue Management Software",
            body_text: "Event management software for restaurants, hotels and venues. Book a demo. Pricing per month, billed annually. Request a demo today.",
            nav_links: "Platform|Pricing|Customers|Login|Request a demo",
            http_address: "50 Beharrell St, Concord, MA", http_phone: "(781) 555-0100"
          })
        )

      assert r.business_model == "SaaS", inspect(r)
    end
  end

  test "a steel fabricator and a CNC machining shop are Manufacturers" do
    for {title, body} <- [
          {"Perth Steel Suppliers - National Steel", "National Lintels is a proud West Australian company founded over 30 years ago, a reliable steel fabricator and supplier of structural steel. Our plant fabricates lintels, beams and columns."},
          {"Usinagem, Caldeiraria e Montagem Industrial | Silmatec", "Silmatec: usinagem CNC e convencional, caldeiraria e montagem de equipamentos industriais. Fundada em 1993, especialista em usinagem."}
        ] do
      r = BusinessClassifier.classify(base(%{http_title: title, body_text: body, http_tech: "WordPress|WooCommerce"}))
      assert r.business_model == "Manufacturer", inspect({title, r})
    end
  end

  test "a dev subscription or a done-for-you service is an Agency, not SaaS" do
    r =
      BusinessClassifier.classify(
        base(%{
          http_title: "Morphixlabs | Premium Development Subscriptions for Startups",
          body_text: "Replace unreliable freelancers and expensive agencies with a flat-rate development subscription. We build web apps, mobile apps and AI integrations for growing teams. Book a call. Our clients ship faster.",
          nav_links: "How it works|Benefits|Pricing|Book a call"
        })
      )

    assert r.business_model == "Agency", inspect(r)
  end

  describe "the templates golden v6 found unflagged" do
    test "parked and for-sale pages" do
      for {title, body} <- [
            {"scambio-coppia.net", "Find information, resources and relevant links for scambio-coppia.net. This domain may be for sale."},
            {"Aftermarket.eu :: domain oferciak.net", "Interested in this domain? If you would like to contact the owner of the domain, click the button below."},
            {"Discover the Thrill of Fishing", "fishingsociety.org is for sale. Why you should join our community. Powered by Computer.Com"},
            {"Dominio a Venda", "Procurando dominio? Dominios premium prontos para impulsionar sua marca."}
          ] do
        assert BusinessClassifier.junk_reason(base(%{http_title: title, body_text: body})) == "parked", title
      end
    end

    test "shells, maintenance pages, default templates and a page that is only its own name" do
      for {title, body, domain} <- [
            {"From Me, Always", "Opening soon. Sign up for our newsletter to be the first to know when we launch. Are you the store owner? Log in here", "frommealways.com"},
            {"Document", "Website under update", "agrona-eg.com"},
            {"Vite in affido", "Website Under Maintenance", "viteinaffido.it"},
            {"Em Manutencao - Elandria Editorial", "Em Manutencao. Estamos aprimorando nossa plataforma editorial para oferecer uma experiencia lendaria.", "elandria.com.br"},
            {"Your awesome title", "Posts Jul 26, 2023 Welcome to Jekyll! subscribe via RSS", "wemesh.ca"},
            {"Test Page for recrutementengage.ca", "Welcome. Your SiteWorx account is up & running like a machine. This is the default test page.", "recrutementengage.ca"},
            {"Haven Hill Farm", "Site Content Detail your services Display real testimonials Announce coming events", "havenhillfarm.com"},
            {"konsoleH :: Login", "This domain does not yet support HTTPS. Please add an SSL Certificate.", "gardill.net"},
            {"skindeepbodyart.net", "skindeepbodyart.net", "skindeepbodyart.net"}
          ] do
        assert BusinessClassifier.junk_reason(base(%{http_title: title, body_text: body, domain: domain})) == "placeholder", title
      end
    end

    test "a real business with lorem ipsum left in a tagline is not junk" do
      sig = base(%{http_title: "Home Automation Company Near Me | EZ-Integration", body_text: "(380) 257-1476 Business Tagline Lorem Ipsum Dolor. Home automation, smart lighting, home theater. EZ-Integration, 4432 Tuller Rd, Dublin, OH. About EZ-Integration: as a leading home automation company we are dedicated to providing exceptional service.", http_address: "4432 Tuller Rd, Dublin, OH", http_phone: "(380) 257-1476", domain: "ezhomeautomationdublinoh.com"})
      assert BusinessClassifier.junk_reason(sig) == ""
    end
  end

  describe "the ML tier waits for 0.7 on the classes it gets wrong" do
    test "Marketplace or Tool at 0.55 with an empty heuristic stays unclassified; at 0.75 it passes; Consulting at 0.55 still passes; SaaS needs 0.7" do
      heur = %{business_model: "", industry: "", confidence: 0.2, method: "none"}
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "Marketplace", industry: "", ml_confidence: 0.55, ml_bm_confidence: 0.55}) == ""
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "Tool", industry: "", ml_confidence: 0.62, ml_bm_confidence: 0.62}) == ""
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "Marketplace", industry: "", ml_confidence: 0.75, ml_bm_confidence: 0.75}) == "Marketplace"
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "Consulting", industry: "", ml_confidence: 0.55, ml_bm_confidence: 0.55}) == "Consulting"
      # ML SaaS was right 2 times in 14 on golden v6, 0 of 5 under 0.65; the provenance test pins 0.7 as shipping.
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "SaaS", industry: "", ml_confidence: 0.6, ml_bm_confidence: 0.6}) == ""
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "SaaS", industry: "", ml_confidence: 0.7, ml_bm_confidence: 0.7}) == "SaaS"
      assert LS.Pipeline.ml_model_for_merge(%{business_model: "Ecommerce", industry: "", ml_confidence: 0.7, ml_bm_confidence: 0.7}) == ""

      merged = LS.Pipeline.merge_classification(heur, %{business_model: "Marketplace", industry: "", ml_confidence: 0.55, ml_bm_confidence: 0.55, ml_industry_confidence: 0.0})
      assert merged.business_model == ""
      merged2 = LS.Pipeline.merge_classification(heur, %{business_model: "Marketplace", industry: "", ml_confidence: 0.75, ml_bm_confidence: 0.75, ml_industry_confidence: 0.0})
      assert merged2.business_model == "Marketplace"
    end
  end
end
