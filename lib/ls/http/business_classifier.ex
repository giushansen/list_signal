defmodule LS.HTTP.BusinessClassifier do
  @moduledoc """
  Deterministic business classifier — 7-layer signal cascade.
  Pure Elixir pattern matching, microsecond speed. No ML.
  """

  @min_confidence 0.55

  @empty_result %{business_model: "", industry: "", confidence: 0.0, method: ""}

  # ===========================================================================
  # PUBLIC API
  # ===========================================================================

  @doc """
  Why the fetched page is not a real business — `""` when it is one.

  Returns `"parked"` (domain for sale / registrar placeholder), `"placeholder"`
  (default Shopify/WordPress/coming-soon shell), `"empty"` (a 2xx/3xx response
  whose page has no title, headline or text — golden v1 found HTTP 200 with a
  0-byte body that no content rule could see), or `"scam"` (fraud template).
  This is the source of the `is_junk` column: junk detection used to happen
  silently inside `classify/1` (the row just got an empty classification),
  which meant parked domains were indistinguishable from
  real-but-unclassifiable businesses — and could be exported to customers as
  leads. `""` means "no junk detected", not "verified real": a page we never
  fetched has nothing to judge — which is why `"empty"` requires a successful
  `http_status`; a failed fetch must not brand the business as junk.

  Golden set v1 (2026-08-12) measured 23% junk in alive-filtered `businesses`
  rows; most of the additions below are the exact platform templates it
  surfaced (Dovendi runs 250k parked domains on one template).
  """
  def junk_reason(signals) when is_map(signals) do
    cond do
      # The registry says who serves the domain; a parking operator's
      # nameservers beat whatever the parking page looks like (2026-10-01:
      # 132K unflagged businesses on Sedo, Bodis, Dovendi and friends).
      LS.DNS.Parking.parked_ns?(signals[:rdap_nameservers]) -> "parked"
      parking_page?(signals) -> "parked"
      v6_parking_page?(signals) -> "parked"
      default_shopify_page?(signals) -> "placeholder"
      generic_placeholder?(signals) -> "placeholder"
      v6_placeholder?(signals) -> "placeholder"
      scam_page?(signals) -> "scam"
      empty_page?(signals) -> "empty"
      true -> ""
    end
  rescue
    _ -> ""
  end

  def junk_reason(_), do: ""

  # Governments are real organizations but never sellable businesses; nih.gov
  # sat in prod as "SaaS@0.62" and surfaced in similar-business widgets
  # (2026-08-17). These TLDs are legally restricted to government bodies, so
  # the classification is deterministic — no scoring layers, no ML. They get a
  # real `Government` label (head v2 also knows the class) so "similar sites"
  # shows other government sites, never SaaS. NOT junk — junk_reason untouched.
  @government_tlds ~w(gov mil)
  @government_result %{business_model: "Government", industry: "Government", confidence: 0.95, method: "tld"}

  def classify(signals) when is_map(signals) do
    # Skip placeholder/dead/infrastructure pages — no real business to classify.
    cond do
      junk_reason(signals) != "" -> @empty_result
      s(signals, :ctl_tld) in @government_tlds -> @government_result
      true -> classify_by_layers(signals)
    end
  rescue
    _ -> @empty_result
  end
  def classify(_), do: @empty_result

  @doc """
  The raw score maps behind `classify/1`, for the golden harness and for
  anyone asking "why did this page get that label". Same layers, same
  order, no thresholds applied.
  """
  @spec scores(map()) :: %{model: map(), industry: map(), methods: [String.t()]}
  def scores(signals) when is_map(signals) do
    {ms, is, methods} = run_layers(signals)
    %{model: ms, industry: is, methods: Enum.reverse(methods)}
  end


  defp classify_by_layers(signals) do
    {model_scores, industry_scores, methods} = run_layers(signals)
    pick_winner(model_scores, industry_scores, methods)
  end

  defp run_layers(signals) do
    model_scores = %{}
    industry_scores = %{}
    methods = []

    {model_scores, industry_scores, methods} = layer_1_tech(signals, model_scores, industry_scores, methods)
    {model_scores, industry_scores, methods} = layer_2_schema(signals, model_scores, industry_scores, methods)
    {model_scores, industry_scores, methods} = layer_3_pages(signals, model_scores, industry_scores, methods)
    {model_scores, industry_scores, methods} = layer_4_nav(signals, model_scores, industry_scores, methods)
    {model_scores, industry_scores, methods} = layer_5_tld(signals, model_scores, industry_scores, methods)
    {model_scores, industry_scores, methods} = layer_6_keywords(signals, model_scores, industry_scores, methods)
    {model_scores, industry_scores, methods} = layer_7_dns(signals, model_scores, industry_scores, methods)
    model_scores = plugin_only_shop(signals, model_scores)
    model_scores = physical_lean(signals, model_scores)
    {model_scores, industry_scores, methods}
  end

  # A street address and a phone number on the homepage is how a physical
  # business presents itself (golden v6: LocalBusiness recall 39%, the
  # misses were plumbers, clinics, gyms and contractors filed as
  # Consulting, Ecommerce or nothing). Alone it is a lean; with trade
  # vocabulary it decides. A factory is physical too, so the lean follows
  # Manufacturer when that is already the stronger of the two (silmatec:
  # "usinagem" 9 lost to the lean's own 5 plus a quote cue).
  #
  # The other way round: a SaaS that sells to restaurants or clinics says
  # so on its homepage, and those words are its customers, not its trade
  # (tripleseat, marvia). A product cue (schema SoftwareApplication, "X
  # management software") outranks them: without an address and phone the
  # trade words go, with one they are halved and the lean is withheld.
  defp physical_lean(signals, ms) do
    lb = Map.get(ms, "LocalBusiness", 0)
    mf = Map.get(ms, "Manufacturer", 0)
    saas = Map.get(ms, "SaaS", 0)
    contact? = local_contact?(signals)

    cond do
      saas >= 8 and not contact? -> Map.delete(ms, "LocalBusiness")
      saas >= 8 and lb > 0 -> Map.put(ms, "LocalBusiness", div(lb, 2))
      contact? and mf > 0 and mf >= lb -> add(ms, "Manufacturer", 5)
      contact? -> add(ms, "LocalBusiness", 5)
      true -> ms
    end
  end

  # ===========================================================================
  # LAYER 1 — Tech stack
  # ===========================================================================

  @tech_ecommerce ~w(Shopify WooCommerce Magento BigCommerce PrestaShop Ecwid OpenCart Shift4Shop Volusion)
  @apps_ecommerce ~w(Klaviyo Judge.me Afterpay Klarna Smile.io ReCharge Yotpo Privy Stamped.io Loox Oberlo DSers Spocket)
  @apps_lms ~w(LearnDash LifterLMS Sensei)
  @apps_community ~w(BuddyPress bbPress)
  @apps_wp_ecom ["Easy Digital Downloads"]

  defp layer_1_tech(signals, ms, is, methods) do
    tech = s(signals, :http_tech)
    apps = s(signals, :http_apps)
    techs = String.split(tech, "|", trim: true)
    app_list = String.split(apps, "|", trim: true)

    ms = Enum.reduce(techs, ms, fn t, acc ->
      cond do
        # WooCommerce scores like the other platforms here, and
        # plugin_only_shop/2 takes most of it back when the page itself
        # argues for another class (golden v6, 2026-10-05: 20 of the 28
        # Ecommerce false positives carried WooCommerce on a steel
        # fabricator, an SAP consultancy, a chamber of commerce, a winery
        # and a trade fair, none with a product count).
        t in @tech_ecommerce -> add(acc, "Ecommerce", 12)
        t == "Substack" -> add(acc, "Newsletter", 12)
        t == "Ghost" -> add(acc, "Media", 10)
        t == "Discourse" -> add(acc, "Community", 12)
        t == "Bubble" -> add(acc, "Tool", 5)
        true -> acc
      end
    end)

    ecom_app_count = Enum.count(app_list, &(&1 in @apps_ecommerce))
    ms = if ecom_app_count > 0, do: add(ms, "Ecommerce", 4 + ecom_app_count * 2), else: ms

    has_lms = Enum.any?(app_list, &(&1 in @apps_lms))
    ms = if has_lms, do: add(ms, "Education", 10), else: ms

    has_community = Enum.any?(app_list, &(&1 in @apps_community))
    ms = if has_community, do: add(ms, "Community", 12), else: ms

    has_wp_ecom = Enum.any?(app_list, &(&1 in @apps_wp_ecom))
    ms = if has_wp_ecom, do: add(ms, "Ecommerce", 10), else: ms

    methods = if ms != %{}, do: ["tech" | methods], else: methods
    {ms, is, methods}
  end

  # WooCommerce is a WordPress plugin, installed on sites that sell nothing
  # (golden v6, 2026-10-05: 20 of 28 Ecommerce false positives, on a steel
  # fabricator, an SAP consultancy, a chamber of commerce, a winery and a
  # trade fair, none with a product count). When the plugin is the only
  # commerce evidence, that is exactly 12 points from layer 1 and no cart
  # or catalogue vocabulary, the plugin keeps a hint's worth: minus 6 when
  # the homepage is in hand and shows no shop (golden v6: that pattern was
  # right once in 14), minus 10 when the page argues for another class with
  # real evidence. Absence of a shop can only be read off a page, so with
  # no page text at all the tech stack stays the whole story and
  # WooCommerce alone still reads as a shop, which is what the tech-only
  # test pins and what a bare storefront is.
  @ecom_platforms_not_woo ~w(Shopify Magento BigCommerce PrestaShop Ecwid OpenCart Shift4Shop Volusion)

  @cart_words ~r/shop now|buy now|add to cart|order now|order online|free shipping|free delivery|our collection|new arrivals|best sellers|on sale|checkout|\bcart\b|\bbasket\b|\bshop\b|\bboutique\b|\bstore\b|products?\b/i

  defp plugin_only_shop(signals, ms) do
    techs = s(signals, :http_tech) |> String.split("|", trim: true)
    apps = s(signals, :http_apps) |> String.split("|", trim: true)
    text = Enum.map_join([:http_title, :h1, :nav_links, :body_text], " ", &s(signals, &1))

    plugin_only? =
      "WooCommerce" in techs and not Enum.any?(techs, &(&1 in @ecom_platforms_not_woo)) and
        not Enum.any?(apps, &(&1 in @apps_ecommerce or &1 in @apps_wp_ecom)) and
        not Regex.match?(@cart_words, text)

    rival? = Enum.any?(ms, fn {k, v} -> k != "Ecommerce" and v >= 3 end)
    page_read? = byte_size(s(signals, :body_text)) >= 40

    # Two points left against a rival: the confidence formula divides by
    # the total, so a larger residue would still sink the rival under the
    # 0.55 floor. Six alone sits at 0.50, under the floor.
    cond do
      plugin_only? and rival? -> Map.update!(ms, "Ecommerce", &(&1 - 10))
      plugin_only? and page_read? -> Map.update!(ms, "Ecommerce", &(&1 - 6))
      true -> ms
    end
  end

  # ===========================================================================
  # LAYER 2 — Schema.org types
  # ===========================================================================

  # LocalBusiness (added 2026-08-12): a business whose operation is physical —
  # trades, clinics, salons, restaurants, venues, brokerages — and whose site
  # is a *presence*, not the product. Golden v1 found 10 of these hiding in
  # Consulting/Tool/Ecommerce predictions; Consulting keeps only
  # professional/advisory services (law, accounting, strategy).
  @schema_to_class %{
    # Software
    "SoftwareApplication" => {"SaaS", 10, nil, 0},
    "WebApplication" => {"SaaS", 10, nil, 0},
    "MobileApplication" => {"SaaS", 8, nil, 0},
    # Products
    "Product" => {"Ecommerce", 8, nil, 0},
    "IndividualProduct" => {"Ecommerce", 9, nil, 0},
    # Healthcare — physical practices are LocalBusiness, not Consulting
    "Dentist" => {"LocalBusiness", 9, "Healthcare", 10},
    "Physician" => {"LocalBusiness", 9, "Healthcare", 10},
    "Hospital" => {"LocalBusiness", 7, "Healthcare", 10},
    "Pharmacy" => {"LocalBusiness", 7, "Healthcare", 9},
    "MedicalClinic" => {"LocalBusiness", 8, "Healthcare", 10},
    "MedicalOrganization" => {"LocalBusiness", 6, "Healthcare", 8},
    # Legal — advisory, stays Consulting
    "LegalService" => {"Consulting", 8, "Legal", 10},
    "Attorney" => {"Consulting", 9, "Legal", 10},
    "Notary" => {"Consulting", 7, "Legal", 8},
    # Food — venues
    "Restaurant" => {"LocalBusiness", 8, "Food & Beverage", 10},
    "CafeOrCoffeeShop" => {"LocalBusiness", 8, "Food & Beverage", 10},
    "Bakery" => {"LocalBusiness", 6, "Food & Beverage", 10},
    "BarOrPub" => {"LocalBusiness", 7, "Food & Beverage", 10},
    "FastFoodRestaurant" => {"LocalBusiness", 8, "Food & Beverage", 10},
    "Brewery" => {"LocalBusiness", 6, "Food & Beverage", 9},
    # Real Estate — brokerages are local businesses (golden v1: corehousing.co.jp)
    "RealEstateAgent" => {"LocalBusiness", 8, "Real Estate", 10},
    # Finance — advisory/institutional, stays Consulting
    "BankOrCreditUnion" => {"Consulting", 6, "Fintech", 10},
    "InsuranceAgency" => {"Consulting", 7, "Fintech", 9},
    "AccountingService" => {"Consulting", 8, "Fintech", 8},
    "FinancialService" => {"Consulting", 6, "Fintech", 9},
    # Stores
    "ClothingStore" => {"Ecommerce", 9, "Fashion", 10},
    "ElectronicsStore" => {"Ecommerce", 9, "General", 6},
    "JewelryStore" => {"Ecommerce", 9, "Fashion", 8},
    "GroceryStore" => {"Ecommerce", 9, "Food & Beverage", 8},
    "FurnitureStore" => {"Ecommerce", 9, "Home & Garden", 10},
    "PetStore" => {"Ecommerce", 9, "General", 6},
    "ShoeStore" => {"Ecommerce", 9, "Fashion", 9},
    "SportingGoodsStore" => {"Ecommerce", 9, "General", 5},
    "HardwareStore" => {"Ecommerce", 8, "Construction & Manufacturing", 6},
    "HomeGoodsStore" => {"Ecommerce", 9, "Home & Garden", 9},
    "Store" => {"Ecommerce", 6, nil, 0},
    # Beauty — venues
    "BeautySalon" => {"LocalBusiness", 8, "Beauty", 10},
    "HairSalon" => {"LocalBusiness", 8, "Beauty", 10},
    "NailSalon" => {"LocalBusiness", 8, "Beauty", 10},
    "DaySpa" => {"LocalBusiness", 8, "Beauty", 10},
    # Construction — trades
    "Electrician" => {"LocalBusiness", 9, "Construction & Manufacturing", 10},
    "Plumber" => {"LocalBusiness", 9, "Construction & Manufacturing", 10},
    "RoofingContractor" => {"LocalBusiness", 9, "Construction & Manufacturing", 10},
    "GeneralContractor" => {"LocalBusiness", 9, "Construction & Manufacturing", 10},
    "HVACBusiness" => {"LocalBusiness", 9, "Construction & Manufacturing", 10},
    # Travel — venues/agencies
    "TravelAgency" => {"LocalBusiness", 7, "Travel", 10},
    "Hotel" => {"LocalBusiness", 8, "Travel", 10},
    "LodgingBusiness" => {"LocalBusiness", 7, "Travel", 9},
    # Education
    "EducationalOrganization" => {"Education", 9, "Education", 9},
    "School" => {"Education", 9, "Education", 10},
    "CollegeOrUniversity" => {"Education", 10, "Education", 10},
    "Course" => {"Education", 8, "Education", 8},
    # Media
    "NewsMediaOrganization" => {"Media", 9, "Media & Entertainment", 9},
    # Generic
    "LocalBusiness" => {"LocalBusiness", 6, nil, 0},
    "ProfessionalService" => {"Consulting", 6, nil, 0},
    "Organization" => {nil, 0, nil, 0},
    "WebSite" => {nil, 0, nil, 0},
  }

  # A WebApplication whose title says calculator or converter is a Tool,
  # not a SaaS (golden v6: timedecimalconverter.com shipped as SaaS 10 vs
  # Tool 6 from exactly this schema row).
  @tool_title_re ~r/calculator|converter|generator|checker|calcul(?:ateur|s)?\b|rechner|calculadora|simulateur/i

  defp layer_2_schema(signals, ms, is, methods) do
    schema_type = s(signals, :http_schema_type)
    og_type = s(signals, :http_og_type)
    matched = false
    tool_title? = s(signals, :http_title) =~ @tool_title_re

    {ms, is, matched} = case Map.get(@schema_to_class, schema_type) do
      {"SaaS", mp, _industry, _ip} when tool_title? ->
        {add(ms, "Tool", mp), is, true}

      {model, mp, industry, ip} ->
        ms = if model, do: add(ms, model, mp), else: ms
        is = if industry, do: add(is, industry, ip), else: is
        {ms, is, true}
      nil -> {ms, is, matched}
    end

    {ms, is, matched} = cond do
      og_type == "product" -> {add(ms, "Ecommerce", 6), is, true}
      og_type == "article" -> {add(ms, "Media", 4), is, true}
      true -> {ms, is, matched}
    end

    methods = if matched, do: ["schema" | methods], else: methods
    {ms, is, methods}
  end

  # ===========================================================================
  # LAYER 3 — Page structure
  # ===========================================================================

  defp layer_3_pages(signals, ms, is, methods) do
    pages = s(signals, :http_pages) |> String.downcase()
    matched = false

    has_pricing = pages =~ "pricing"
    has_login = pages =~ "login" or pages =~ "signin" or pages =~ "sign-in"
    has_docs = pages =~ "docs" or pages =~ "documentation" or pages =~ "api"
    has_trial = pages =~ "free-trial" or pages =~ "trial" or pages =~ "demo"
    has_cart = pages =~ "cart" or pages =~ "checkout"
    has_shop = pages =~ "shop" or pages =~ "products" or pages =~ "collections"
    has_portfolio = pages =~ "portfolio" or pages =~ "our-work" or pages =~ "work"
    has_cases = pages =~ "case-stud"
    has_courses = pages =~ "courses" or pages =~ "lessons" or pages =~ "classes"
    has_enroll = pages =~ "enroll" or pages =~ "register"
    has_properties = pages =~ "properties" or pages =~ "listings"
    has_directory = pages =~ "directory"
    has_submit = pages =~ "submit"

    # SaaS triple — pathognomonic
    {ms, matched} = if has_pricing and has_login and has_docs do
      {add(ms, "SaaS", 15), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_pricing and has_login and !has_docs do
      {add(ms, "SaaS", 10), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_pricing and has_trial do
      {add(ms, "SaaS", 9), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_cart or pages =~ "checkout" do
      {add(ms, "Ecommerce", 10), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_shop and !has_pricing do
      {add(ms, "Ecommerce", 7), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_portfolio and has_cases and !has_pricing do
      {add(ms, "Agency", 10), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_portfolio and !has_pricing and !has_cart do
      {add(ms, "Agency", 5), true}
    else
      {ms, matched}
    end

    {ms, matched} = if has_courses and has_enroll do
      {add(ms, "Education", 10), true}
    else
      {ms, matched}
    end

    {ms, is, matched} = if has_properties do
      {ms, add(is, "Real Estate", 7), true}
    else
      {ms, is, matched}
    end

    {ms, matched} = if has_directory and has_submit do
      {add(ms, "Directory", 11), true}
    else
      {ms, matched}
    end

    methods = if matched, do: ["pages" | methods], else: methods
    {ms, is, methods}
  end

  # ===========================================================================
  # LAYER 4 — Nav link text
  # ===========================================================================

  # When the block store found no <nav>, the header is still the first
  # thing in the body text, so the opening of the body stands in for it
  # (golden v6: shiftcycle, sportful, benchpro and duasocial all carried
  # "Features Pricing Login" there and no nav_links).
  defp layer_4_nav(signals, ms, is, methods) do
    nav = s(signals, :nav_links) |> String.downcase()
    nav = if nav == "", do: s(signals, :body_text) |> String.downcase() |> String.slice(0, 400), else: nav

    if nav == "" do
      {ms, is, methods}
    else
      matched = false

      {ms, matched} = if nav =~ ~r/shop|products|collections/ do
        {add(ms, "Ecommerce", 6), true}
      else
        {ms, matched}
      end

      {ms, matched} = if nav =~ ~r/pricing|preise|planos|tarifs/ and nav =~ ~r/docs|api|log ?in|sign ?in|sign ?up|get started|demo|early access|features|funktionen/ do
        {add(ms, "SaaS", 7), true}
      else
        {ms, matched}
      end

      {ms, matched} = if nav =~ ~r/portfolio|our work|case stud/ do
        {add(ms, "Agency", 6), true}
      else
        {ms, matched}
      end

      {ms, matched} = if nav =~ ~r/courses|programs|learn|curriculum/ do
        {add(ms, "Education", 6), true}
      else
        {ms, matched}
      end

      {is, matched} = if nav =~ ~r/our menu|food menu|dinner|lunch|reservat/ do
        {add(is, "Food & Beverage", 6), true}
      else
        {is, matched}
      end

      {is, matched} = if nav =~ ~r/properties|homes|real estate|listings/ do
        {add(is, "Real Estate", 6), true}
      else
        {is, matched}
      end

      {is, matched} = if nav =~ ~r/practice areas|attorneys|legal/ do
        {add(is, "Legal", 6), true}
      else
        {is, matched}
      end

      {is, matched} = if nav =~ ~r/patients?|appointments?|dentist|doctor/ do
        {add(is, "Healthcare", 5), true}
      else
        {is, matched}
      end

      methods = if matched, do: ["nav" | methods], else: methods
      {ms, is, methods}
    end
  end

  # ===========================================================================
  # LAYER 5 — TLD
  # ===========================================================================

  @tld_industry %{
    "edu" => {"Education", 12},
    "gov" => {"General", 10},
    "law" => {"Legal", 10},
    "legal" => {"Legal", 9},
    "attorney" => {"Legal", 9},
    "dental" => {"Healthcare", 9},
    "health" => {"Healthcare", 8},
    "clinic" => {"Healthcare", 8},
    "hospital" => {"Healthcare", 9},
    "restaurant" => {"Food & Beverage", 9},
    "cafe" => {"Food & Beverage", 8},
    "bank" => {"Fintech", 12},
    "insurance" => {"Fintech", 9},
    "realty" => {"Real Estate", 9},
    "homes" => {"Real Estate", 8},
    # NOTE: ".ai" is a generic startup TLD now (Anguilla), not an AI-industry signal — it was
    # tagging 94k non-AI sites as "AI & ML". Genuine AI is caught by the keyword rule instead.
    "dev" => {"DevTools", 5},
    "travel" => {"Travel", 8},
    "tours" => {"Travel", 8},
    "construction" => {"Construction & Manufacturing", 9},
  }

  defp layer_5_tld(signals, ms, is, methods) do
    tld = s(signals, :ctl_tld) |> String.downcase()
    case Map.get(@tld_industry, tld) do
      {industry, pts} ->
        is = add(is, industry, pts)
        # .edu also boosts Education model
        ms = if tld == "edu", do: add(ms, "Education", 10), else: ms
        {ms, is, ["tld" | methods]}
      nil ->
        {ms, is, methods}
    end
  end

  # ===========================================================================
  # LAYER 6 — Keywords
  # ===========================================================================

  # Business model patterns: {regex, model, points}
  @model_keywords [
    {~r/\bsaas\b|cloud[- ]based|cloud platform/i, "SaaS", 7},
    {~r/free trial|start free|try free|try it free/i, "SaaS", 5},
    # How a SaaS introduces itself (golden v6: 19 of 41 SaaS homepages scored
    # nothing; "the AI platform for claim integrity", "workforce management
    # for temporary staffing", "ERP for multi-store retail" were all there).
    {~r/\b(?:platform|software|erp|crm|saas|operating system|app|solution) (?:for|built for|designed for|that)\b|\bthe (?:ai |all[- ]in[- ]one )?(?:platform|software|operating system) for\b|\b(?:ai|analytics|automation|scheduling|benchmarking|management|productivity)[- ](?:platform|software|app)\b/i, "SaaS", 8},
    {~r/get early access|join (?:the )?waitlist|early access|beta is live|\berp\b|workforce management|content planner|chatbot solution|as a service\b|simple apis|integrations? (?:&|and) apis?/i, "SaaS", 6},
    {~r/\b(?:management|accounting|scheduling|booking|invoicing|payroll|crm|hr|inventory|marketing|practice|property|compliance|analytics|screening|coding|tracking) (?:software|platform|suite|tool)\b|software for\b|all[- ]in[- ]one (?:platform|software|solution)|screener\b|tracker\b/i, "SaaS", 10},
    {~r/web hosting|shared hosting|\bvps\b|dedicated server|managed hosting|cloud hosting/i, "SaaS", 6},
    {~r/per user|per seat|per month|billed annually|billed monthly/i, "SaaS", 6},
    {~r/request (?:a )?demo|book (?:a )?demo|schedule (?:a )?demo|get (?:a )?demo/i, "SaaS", 5},
    {~r/sign up free|get started free|start your free/i, "SaaS", 4},
    {~r/shop now|buy now|add to cart|order now|order online/i, "Ecommerce", 7},
    {~r/free shipping|free delivery|fast shipping/i, "Ecommerce", 6},
    {~r/our collection|new arrivals|best sellers|on sale|shop (?:our|the|all)/i, "Ecommerce", 5},
    {~r/digital agency|marketing agency|creative agency|design agency|web agency|full[- ]service agency/i, "Agency", 8},
    {~r/we (?:help|work with) (?:brands|clients|companies)/i, "Agency", 5},
    {~r/our clients|client (?:results|success|stories)|case stud(?:y|ies)/i, "Agency", 4},
    {~r/consulting firm|management consulting|strategy consulting/i, "Consulting", 7},
    # Golden v6 (2026-10-05): Consulting recall 44%. "SAP Consulting", a
    # "cabinet de conseil", accountants and advisors matched nothing above.
    {~r/\bconsulting\b|consultancy|consultants?\b|cabinet de conseil|unternehmensberatung|\bberatung\b|consultor(?:ia|ía)|advisory (?:firm|services|practice)|accountants?\b|accounting (?:firm|services)|bookkeeping|commercialisti|expert[- ]comptable|tax (?:advisor|preparation|advisory)|notary|notariat|psychotherap|market research|forensic/i, "Consulting", 7},
    {~r/law firm|attorneys?\b|lawyers?\b|legal (?:services|practice|team)/i, "Consulting", 7},
    # Newsletter must BE a publication, not merely have a signup box — golden
    # v1: a Brazilian web store's signup widget shipped Newsletter@1.0
    # (artedeminasmg.com.br), and "email tools" vendors matched on "email".
    {~r/(?:weekly|daily|monthly) (?:newsletter|digest|brief)|newsletter archive|read (?:past|previous) issues|join [\d,.]+ (?:readers|subscribers)/i, "Newsletter", 5},
    {~r/\bmarketplace\b|buy and sell|connect buyers/i, "Marketplace", 6},
    {~r/online course|bootcamp|online (?:learning|classes|school)/i, "Education", 5},
    {~r/calculator|generator|converter|checker|(?:free )?tool\b|calcul(?:ateur|s)?\b|rechner|calculadora|simulateur|simulador/i, "Tool", 6},
    {~r/\bcommunity forum\b|\bdiscussion board\b|\bforum topic|online community|members area/i, "Community", 4},
    {~r/latest news|breaking news|editorial|journalism|reporting/i, "Media", 5},
    {~r/directory|listing|submit your|find (?:a |local )/i, "Directory", 4},
    # LocalBusiness: trade/venue vocabulary and the get-a-quote/visit-us
    # pattern that brochure sites of physical businesses share.
    {~r/(?:free|request a|get a(?:n instant)?) quote|call us today|licensed and insured|fully insured|opening hours|visit our (?:store|showroom)/i, "LocalBusiness", 6},
    {~r/joinery|glazier|glazing|plumbing|electricians?\b|roofing|landscaping|carpentry|locksmith|removals|scaffolding/i, "LocalBusiness", 5},
    {~r/book (?:a table|an appointment)|our (?:clinic|practice|salon|studio|showroom)|personal train(?:er|ing)|crossfit/i, "LocalBusiness", 5},
    # Golden v6 (2026-10-05): the trades, clinics and venues production
    # filed under Consulting, Ecommerce or nothing.
    # The text is lowercased and stems must match their inflections
    # ("remodeling", "clinica"), so no trailing boundary. A trade word in
    # the title scores 8; with the address-and-phone lean (5) or a presence
    # phrase it clears the floor, alone it does not, which is the point.
    {~r/\b(?:dentist|dental|clinics?\b|cl[ií]nicas?\b|physio|chiropract|orthodont|veterinar|vets?\b|barber|hair salon|nail salon|day spa|massage|tattoo|gym\b|fitness|muay thai|yoga studio|remodel|renovat|general contractor|hvac|heating (?:&|and) (?:cooling|air)|plumbing|plumber|plombier|electrician|roofing|asphalt paving|paving (?:contractor|company|services|stones)|concrete (?:contractor|work|services|driveway|slab|pour)|masonry|maçonnerie|janitorial|cleaning services|house cleaning|pressure washing|window cleaning|irrigation|lawn care|pest control|movers|moving services|limousine|black car|car service|towing|auto repair|dent repair|body shop|appliance repair|restaurant|ristorante|bistro|brasserie|pizzeria|bakery|boulangerie|cafe\b|coffee shop|pub\b|bed and breakfast|ferienwohnung|holiday (?:apartments?|rentals?|cottage)|guest ?house|real estate agency|inmobiliaria|immobilier|estate agents?)/i, "LocalBusiness", 8},
    {~r/serving (?:the )?(?:greater |all of )?[a-z]+|near me\b|call (?:us )?(?:today|now)\b|book (?:now|online)\b|same[- ]day service|24\/7 (?:emergency|dispatch|service)|free estimates?\b|get a free estimate|licensed (?:and|&) insured|family[- ]owned|locally owned|our (?:team|technicians) (?:will|can) (?:come|visit)|we come to you/i, "LocalBusiness", 5},
    # Makers: production vocabulary (golden v6: Manufacturer recall 9%, a
    # steel fabricator, a glass-jar plant and a CNC shop read as Ecommerce
    # or Consulting).
    {~r/\b(?:manufactur|we manufacture|(?:steel|metal) fabricat|fabricators?\b|usinagem|caldeiraria|cnc\b|produttore|hersteller|fabricante|fabrik\b|factory|foundry|machining|tooling|injection mold|oem\b|our (?:plant|production facility))/i, "Manufacturer", 9},
    {~r/\b(?:structural steel|steel (?:suppliers?|works|structures|beams)|lintels|machinery|industrial (?:equipment|assembly|automation)|precision parts|powder metal|sheet metal|welding|forging|castings?\b|extrusion|production line)/i, "Manufacturer", 6},
    # Service shops that build software or run campaigns for clients are
    # agencies, whatever they call their subscription (golden v6: SaaS
    # false positives were dev subscriptions, outbound services, studios).
    {~r/software (?:house|studio|agency)|development agency|dev shop|done[- ]for[- ]you|we (?:build|design|develop|create) (?:websites|web ?apps|apps|software|products|brands) for|development subscription|book a (?:call|discovery call)/i, "Agency", 6},
  ]

  # Classes golden v1 measured at ≤33% precision, all poisoned by body-text
  # keyword hits ("MarketPlace" in a consultancy's service list, "converter"
  # in a widget). They may only score from title/H1/meta — a real newsletter
  # or marketplace says so above the fold.
  @primary_only_models MapSet.new(~w(Newsletter Marketplace Tool Community Directory))

  # Industry patterns: {regex, industry, points}
  @industry_keywords [
    {~r/\bfintech\b|payment[s ]?(?:platform|gateway)|(?:payment processing)|banking|lending|mortgage|(?:invest|trading)\b|crypto(?:currency)?/i, "Fintech", 6},
    {~r/\bhipaa\b|telemedicine|telehealth|\behr\b|clinical|patient[s ]?(?:care|portal)|medical|healthcare/i, "Healthcare", 7},
    {~r/marketing (?:platform|software|tool|automation)|(?:\bseo\b|\bppc\b|\bcrm\b)|email marketing|lead gen/i, "Marketing", 6},
    {~r/\bhr\b software|recruiting|payroll|onboarding|\bats\b|applicant tracking|talent (?:management|acquisition)/i, "HR & Recruiting", 6},
    {~r/law firm|attorney|litigation|compliance|personal injury|legal (?:services|practice)/i, "Legal", 7},
    {~r/real estate|homes for sale|\bmls\b|realtor|property (?:management|listings?)/i, "Real Estate", 7},
    {~r/skincare|makeup|cosmetic[s]?|beauty|serum|moisturizer|salon/i, "Beauty", 6},
    {~r/fashion|apparel|clothing|footwear|jewelry|designer|boutique/i, "Fashion", 6},
    {~r/restaurant|bakery|coffee shop|gluten[- ]free|food (?:delivery|ordering)|catering|cuisine|brewery|winery|bistro|pizz/i, "Food & Beverage", 6},
    # Genuine AI/ML only — "ai-powered"/"ai-native" is 2026 marketing fluff on non-AI products
    # (observability, hosting, forms…), so it's intentionally NOT matched here.
    {~r/machine learning|\bgpt\b|\bllm\b|generative ai|artificial intelligence|neural net|deep learning|\bml model|\bai model/i, "AI & ML", 6},
    {~r/developer[s ]?(?:tool|platform)|(?:\bsdk\b|\bapi\b|devops|ci\/cd)|kubernetes|docker|open[- ]?source|observability|\bapm\b|monitoring/i, "DevTools", 6},
    {~r/cybersecurity|infosec|threat (?:detection|intelligence)|vulnerability|penetration test|\bsiem\b/i, "Security", 7},
    {~r/productivity|project management|task management|workflow|collaboration tool|team (?:management|communication)/i, "Productivity", 5},
    {~r/logistics|supply chain|shipping (?:software|platform)|fleet management|warehouse/i, "Logistics", 6},
    {~r/construction|contractor|building (?:materials|supplies)|manufacturing|industrial/i, "Construction & Manufacturing", 6},
    {~r/garden|landscaping|home (?:improvement|decor|renovation)|furniture|interior design/i, "Home & Garden", 5},
    {~r/data analytics|business intelligence|\bbi\b (?:tool|platform|solution)|data (?:visualization|warehouse|pipeline)/i, "Data & Analytics", 6},
    {~r/online (?:learning|education|school|university)|e-?learning|\blms\b|student|academic|curriculum/i, "Education", 5},
    {~r/hotel|travel (?:agency|booking)|tourism|vacation|flight|destination/i, "Travel", 6},
    {~r/streaming|entertainment|gaming|music (?:label|platform|production)|podcast|media (?:company|production)|film (?:production|studio)|tv (?:show|series)/i, "Media & Entertainment", 5},
    {~r/ecommerce|e-commerce|online (?:store|shop|retail)|retail (?:platform|solution)/i, "Ecommerce & Retail", 5},
  ]

  defp layer_6_keywords(signals, ms, is, methods) do
    title = s(signals, :http_title) |> String.downcase()
    h1 = s(signals, :h1) |> String.downcase()
    meta = s(signals, :http_meta_description) |> String.downcase()
    body = s(signals, :body_text) |> String.downcase()

    # Title + H1 + meta = primary (full points), body = secondary (half points)
    primary = Enum.join([title, h1, meta], " ")

    matched = false

    {ms, matched} = Enum.reduce(@model_keywords, {ms, matched}, fn {regex, model, pts}, {acc, m} ->
      primary_match = Regex.match?(regex, primary)
      body_match = Regex.match?(regex, body) and not MapSet.member?(@primary_only_models, model)
      cond do
        primary_match -> {add(acc, model, pts), true}
        body_match -> {add(acc, model, div(pts, 2)), true}
        true -> {acc, m}
      end
    end)

    {is, matched} = Enum.reduce(@industry_keywords, {is, matched}, fn {regex, industry, pts}, {acc, m} ->
      primary_match = Regex.match?(regex, primary)
      body_match = Regex.match?(regex, body)
      cond do
        primary_match -> {add(acc, industry, pts), true}
        body_match -> {add(acc, industry, div(pts, 2)), true}
        true -> {acc, m}
      end
    end)

    methods = if matched, do: ["keywords" | methods], else: methods
    {ms, is, methods}
  end

  # ===========================================================================
  # LAYER 7 — DNS TXT signals
  # ===========================================================================

  defp layer_7_dns(signals, ms, is, methods) do
    txt = s(signals, :dns_txt) |> String.downcase()
    if txt == "" do
      {ms, is, methods}
    else
      matched = false

      {ms, matched} = if txt =~ "intercom" do
        {add(ms, "SaaS", 2), true}
      else
        {ms, matched}
      end

      {is, matched} = if txt =~ "hubspot" do
        {add(is, "Marketing", 2), true}
      else
        {is, matched}
      end

      {ms, matched} = if txt =~ "shopify" do
        {add(ms, "Ecommerce", 2), true}
      else
        {ms, matched}
      end

      {ms, is, matched} = if txt =~ "atlassian" do
        {add(ms, "SaaS", 2), add(is, "DevTools", 2), true}
      else
        {ms, is, matched}
      end

      methods = if matched, do: ["dns" | methods], else: methods
      {ms, is, methods}
    end
  end

  # ===========================================================================
  # SCORING
  # ===========================================================================

  # Classes whose golden-v1 precision was ≤33% must clear a higher bar before
  # we sell the label; SaaS/Education (≥85%) keep the default. Re-derive these
  # from `mix ls.golden_reclassify` whenever the scoring changes.
  # Newsletter sits at 0.70, not 0.75: a Substack-platform tech signal (12pts,
  # pathognomonic) lands at 0.72 under the evidence prior, and 0.75 was
  # measured killing a true Substack publication (carlhead.com, golden v1).
  @class_min_confidence %{
    "Marketplace" => 0.75,
    "Newsletter" => 0.70,
    "Tool" => 0.70,
    "Community" => 0.70,
    "Directory" => 0.65
  }

  # Industry is scored on its OWN evidence since 2026-08-12: it used to ride
  # the model's confidence gate, so "Cybersecurity Inc" with an unclear
  # business model lost its industry too. The bar is lower than the model's
  # because a single title keyword is decent evidence for an industry, while
  # it is exactly what mislabeled business models in golden v1.
  @industry_min_confidence 0.45

  defp pick_winner(model_scores, industry_scores, methods) do
    model = winner(model_scores)
    industry = winner(industry_scores)
    model_pts = if model, do: Map.get(model_scores, model, 0), else: 0
    industry_pts = if industry, do: Map.get(industry_scores, industry, 0), else: 0

    model_conf = side_confidence(model_pts, model_scores)
    industry_conf = side_confidence(industry_pts, industry_scores)

    model_ok? = model != nil and model_conf >= Map.get(@class_min_confidence, model, @min_confidence)
    industry_ok? = industry != nil and industry_conf >= @industry_min_confidence
    method = methods |> Enum.reverse() |> Enum.uniq() |> Enum.join("+")

    cond do
      model_ok? ->
        %{business_model: model, industry: (if industry_ok?, do: industry, else: ""),
          confidence: model_conf, method: method}

      # Industry-only result: business_model stays empty, and `confidence`
      # then describes the industry label (meaning change 2026-08-12 —
      # previously one blended confidence gated both fields together).
      industry_ok? ->
        %{business_model: "", industry: industry, confidence: industry_conf, method: method}

      true ->
        @empty_result
    end
  end

  # Confidence of ONE dimension (model or industry) from its score map.
  # The evidence prior in the denominator is the fix for golden v1's
  # Newsletter@1.0: with a single weak signal the old ratio was
  # points/points = 1.0, so one 5-pt keyword shipped at 0.6 and stacked weak
  # matches shipped at 1.0. The prior fades as absolute evidence grows —
  # a flat +4 was measured collapsing coverage 86%→12% (the harness caught it).
  defp side_confidence(0, _scores), do: 0.0

  defp side_confidence(pts, scores) do
    total = Map.values(scores) |> Enum.sum() |> max(1)
    prior = max(3 - pts / 5, 0)
    ratio = pts / (total + prior)
    abs_boost = min(pts / 25.0, 1.0)
    Float.round((ratio * 0.5 + abs_boost * 0.5) |> min(0.99), 2)
  end

  defp winner(scores) when map_size(scores) == 0, do: nil
  defp winner(scores) do
    {cat, _} = Enum.max_by(scores, fn {_, v} -> v end)
    cat
  end

  # ===========================================================================
  # HELPERS
  # ===========================================================================

  defp add(scores, category, points), do: Map.update(scores, category, points, &(&1 + points))

  defp s(signals, key) do
    case Map.get(signals, key) do
      v when is_binary(v) -> v
      _ -> ""
    end
  end

  # Detects Shopify password/setup pages that show generic platform copy
  # instead of the actual store content. These pages contain "payment solution"
  # in their meta description which falsely triggers Fintech industry matching.
  # Every non-obvious string below carries the golden-v1 domain that produced
  # it — these are shared platform templates, so each string covers thousands
  # of domains, not one.
  defp parking_page?(signals) do
    title = s(signals, :http_title) |> String.downcase()
    body = s(signals, :body_text) |> String.downcase()

    String.contains?(title, "domain for sale") or
      String.contains?(title, "parked domain") or
      String.contains?(title, "website coming soon") or
      String.contains?(body, "this domain is for sale") or
      String.contains?(body, "buy this domain") or
      title == "storefront" or
      # golden v1: webaccept.com (Sedo FR), ebikefinder.es (DE broker),
      # fancythatface.net (short.io), laurenpegg.nz (1st Domains)
      String.contains?(title, "est à vendre") or
      String.contains?(title, "wird zum kauf angeboten") or
      String.contains?(title, "steht zum verkauf") or
      String.contains?(title, "is a custom short domain") or
      String.contains?(title, "your future website") or
      String.contains?(body, "domain is currently parked") or
      String.contains?(body, "domain name is managed by dovendi") or
      String.contains?(body, "domain is available for sale")
  end

  # Hosting/builder shells with no business content behind them.
  defp generic_placeholder?(signals) do
    title = s(signals, :http_title) |> String.downcase()
    body = s(signals, :body_text) |> String.downcase()

    # golden v1: tymsapp.io, flyprimeglobal.com, citreoro.com (default WP),
    # instituteforzambiandevelopment.org (Bizland), comfortathome.org
    # (untouched Google Sites), thebarnett.net, mailmaag.com
    title == "hostinger horizons" or
      title == "my google ai studio app" or
      String.contains?(title, "just another wordpress site") or
      String.contains?(title, "otro sitio realizado con wordpress") or
      String.starts_with?(title, "listmonk - ") or
      String.contains?(body, "this site is temporarily unavailable") or
      String.contains?(body, "this is a mail-in-a-box") or
      (String.contains?(body, "your page title") and String.contains?(body, "google sites")) or
      # golden v1: grupolisto.com (untouched Spanish WP), unitem.nl (404 as
      # homepage), thisjustin.com (broken sale-redirect), actpractice.org
      # (cloaked redirect wall)
      String.contains?(body, "página de ejemplo") or
      String.contains?(title, "page not found") or
      String.contains?(title, "pagina niet gevonden") or
      String.contains?(body, "page cannot be displayed") or
      String.contains?(body, "checking if you're a real user")
  end

  # Golden v6 (2026-10-05): 42 of 320 sampled "businesses" were not one,
  # and none was flagged. Every string below names a template, not a site.
  defp v6_parking_page?(signals) do
    title = s(signals, :http_title) |> String.downcase()
    body = s(signals, :body_text) |> String.downcase()

    String.contains?(body, "domain may be for sale") or
      String.contains?(body, "this domain may be for sale") or
      String.contains?(title, "aftermarket.eu :: domain") or
      String.contains?(body, "interested in this domain?") or
      (String.contains?(body, "is for sale.") and String.contains?(body, "powered by computer.com")) or
      String.contains?(title, "domínio à venda") or String.contains?(title, "dominio a venda") or
      String.contains?(body, "procurando domínio") or
      String.contains?(title, "domain for sale") or String.contains?(title, "domaine à vendre")
  end

  defp v6_placeholder?(signals) do
    title = s(signals, :http_title) |> String.downcase() |> String.trim()
    body = s(signals, :body_text) |> String.downcase() |> String.trim()
    domain = s(signals, :domain) |> String.downcase()

    (String.contains?(body, "opening soon") and (String.contains?(body, "store owner") or String.contains?(body, "be the first to know when we launch"))) or
      String.contains?(body, "website under update") or
      String.contains?(body, "website under maintenance") or
      String.contains?(title, "em manutenção") or String.contains?(body, "estamos aprimorando nossa plataforma") or
      String.contains?(body, "site under construction") or
      String.contains?(title, "your awesome title") or
      String.contains?(body, "default test page") or String.contains?(body, "siteworx account") or
      (String.contains?(body, "detail your services") and String.contains?(body, "display real testimonials")) or
      String.contains?(body, "this domain does not yet support https") or
      String.contains?(title, "konsoleh :: login") or
      # A page whose whole visible text is its own domain name (golden v6:
      # skindeepbodyart.net, scambio-coppia.net).
      (domain != "" and String.replace(body, ~r/\s+/, "") == domain) or
      (domain != "" and title == domain and String.length(body) < 40)
  end

  # Pure: the homepage carries a street address and a phone number.
  defp local_contact?(signals) do
    s(signals, :http_address) != "" and s(signals, :http_phone) != ""
  end

  # Narrow, template-level fraud patterns only — a wrong "scam" on a real
  # business is worse than a missed one, same asymmetry as parked.
  defp scam_page?(signals) do
    body = s(signals, :body_text) |> String.downcase()
    # golden v1: coinny-gateway.com ("withdrawal resolution center" for
    # money stuck on fake trading platforms — a recovery-scam template)
    String.contains?(body, "stuck funds") or
      String.contains?(body, "withdrawal resolution center") or
      (String.contains?(body, "recover") and String.contains?(body, "withdrawal") and
         String.contains?(body, "btc wallet"))
  end

  # A successful response with nothing on it. Requires 200..399 so a failed
  # or blocked fetch never brands the business (WAF pages have titles, so
  # they don't land here either), and skips JS-rendered shells — golden v1
  # junked UBA bank and Mountain America CU, both real businesses behind
  # empty JS bootstraps that the browser tier renders fine. golden v1 catch:
  # serviceinnovation.org, HTTP 200 with a 0-byte body.
  defp empty_page?(signals) do
    status = Map.get(signals, :http_status)

    is_integer(status) and status in 200..399 and
      Map.get(signals, :is_js_site) != true and
      s(signals, :http_title) == "" and
      s(signals, :h1) == "" and
      s(signals, :http_meta_description) == "" and
      String.length(s(signals, :body_text)) < 40 and
      s(signals, :http_pages) == ""
  end

  defp default_shopify_page?(signals) do
    title = s(signals, :http_title)
    body = s(signals, :body_text)

    String.contains?(title, "Ecommerce Software by Shopify") or
      String.contains?(title, "E-Commerce-Software von Shopify") or
      String.contains?(title, "E-commercesoftware van Shopify") or
      String.contains?(title, "E-Ticaret Yazılımı") or
      String.contains?(title, "logiciel de commerce") or
      String.contains?(title, "Software di ecommerce di Shopify") or
      title == "My Store" or
      title == "Opening Soon" or
      String.contains?(body, "store is currently unavailable") or
      String.contains?(body, "is currently unavailable") or
      String.contains?(body, "store is coming soon") or
      String.contains?(body, "Opening Soon")
  end
end
