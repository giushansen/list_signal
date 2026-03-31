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

  def classify(signals) when is_map(signals) do
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

    pick_winner(model_scores, industry_scores, methods)
  rescue
    _ -> @empty_result
  end
  def classify(_), do: @empty_result

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
        t in @tech_ecommerce -> add(acc, "Ecommerce", 12)
        t == "Substack" -> add(acc, "Newsletter", 12)
        t == "Ghost" -> add(acc, "Media", 10)
        t == "Discourse" -> add(acc, "Community", 10)
        t == "Bubble" -> add(acc, "Tool", 5)
        true -> acc
      end
    end)

    ecom_app_count = Enum.count(app_list, &(&1 in @apps_ecommerce))
    ms = if ecom_app_count > 0, do: add(ms, "Ecommerce", 4 + ecom_app_count * 2), else: ms

    has_lms = Enum.any?(app_list, &(&1 in @apps_lms))
    ms = if has_lms, do: add(ms, "Education", 10), else: ms

    has_community = Enum.any?(app_list, &(&1 in @apps_community))
    ms = if has_community, do: add(ms, "Community", 8), else: ms

    has_wp_ecom = Enum.any?(app_list, &(&1 in @apps_wp_ecom))
    ms = if has_wp_ecom, do: add(ms, "Ecommerce", 10), else: ms

    methods = if ms != %{}, do: ["tech" | methods], else: methods
    {ms, is, methods}
  end

  # ===========================================================================
  # LAYER 2 — Schema.org types
  # ===========================================================================

  @schema_to_class %{
    # Software
    "SoftwareApplication" => {"SaaS", 10, nil, 0},
    "WebApplication" => {"SaaS", 10, nil, 0},
    "MobileApplication" => {"SaaS", 8, nil, 0},
    # Products
    "Product" => {"Ecommerce", 8, nil, 0},
    "IndividualProduct" => {"Ecommerce", 9, nil, 0},
    # Healthcare
    "Dentist" => {"Consulting", 8, "Healthcare", 10},
    "Physician" => {"Consulting", 8, "Healthcare", 10},
    "Hospital" => {"Consulting", 6, "Healthcare", 10},
    "Pharmacy" => {"Ecommerce", 6, "Healthcare", 9},
    "MedicalClinic" => {"Consulting", 7, "Healthcare", 10},
    "MedicalOrganization" => {"Consulting", 6, "Healthcare", 8},
    # Legal
    "LegalService" => {"Consulting", 8, "Legal", 10},
    "Attorney" => {"Consulting", 9, "Legal", 10},
    "Notary" => {"Consulting", 7, "Legal", 8},
    # Food
    "Restaurant" => {"Consulting", 6, "Food & Beverage", 10},
    "CafeOrCoffeeShop" => {"Consulting", 6, "Food & Beverage", 10},
    "Bakery" => {"Ecommerce", 5, "Food & Beverage", 10},
    "BarOrPub" => {"Consulting", 5, "Food & Beverage", 10},
    "FastFoodRestaurant" => {"Consulting", 6, "Food & Beverage", 10},
    "Brewery" => {"Consulting", 5, "Food & Beverage", 9},
    # Real Estate
    "RealEstateAgent" => {"Consulting", 7, "Real Estate", 10},
    # Finance
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
    # Beauty
    "BeautySalon" => {"Consulting", 6, "Beauty", 10},
    "HairSalon" => {"Consulting", 6, "Beauty", 10},
    "NailSalon" => {"Consulting", 6, "Beauty", 10},
    "DaySpa" => {"Consulting", 6, "Beauty", 10},
    # Construction
    "Electrician" => {"Consulting", 7, "Construction & Manufacturing", 10},
    "Plumber" => {"Consulting", 7, "Construction & Manufacturing", 10},
    "RoofingContractor" => {"Consulting", 7, "Construction & Manufacturing", 10},
    "GeneralContractor" => {"Consulting", 7, "Construction & Manufacturing", 10},
    "HVACBusiness" => {"Consulting", 7, "Construction & Manufacturing", 10},
    # Travel
    "TravelAgency" => {"Consulting", 7, "Travel", 10},
    "Hotel" => {"Consulting", 6, "Travel", 10},
    "LodgingBusiness" => {"Consulting", 6, "Travel", 9},
    # Education
    "EducationalOrganization" => {"Education", 9, "Education", 9},
    "School" => {"Education", 9, "Education", 10},
    "CollegeOrUniversity" => {"Education", 10, "Education", 10},
    "Course" => {"Education", 8, "Education", 8},
    # Media
    "NewsMediaOrganization" => {"Media", 9, "Media & Entertainment", 9},
    # Generic
    "LocalBusiness" => {"Consulting", 3, nil, 0},
    "Organization" => {nil, 0, nil, 0},
    "WebSite" => {nil, 0, nil, 0},
  }

  defp layer_2_schema(signals, ms, is, methods) do
    schema_type = s(signals, :http_schema_type)
    og_type = s(signals, :http_og_type)
    matched = false

    {ms, is, matched} = case Map.get(@schema_to_class, schema_type) do
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
      {add(ms, "Directory", 9), true}
    else
      {ms, matched}
    end

    methods = if matched, do: ["pages" | methods], else: methods
    {ms, is, methods}
  end

  # ===========================================================================
  # LAYER 4 — Nav link text
  # ===========================================================================

  defp layer_4_nav(signals, ms, is, methods) do
    nav = s(signals, :nav_links) |> String.downcase()
    if nav == "" do
      {ms, is, methods}
    else
      matched = false

      {ms, matched} = if nav =~ ~r/shop|products|collections/ do
        {add(ms, "Ecommerce", 6), true}
      else
        {ms, matched}
      end

      {ms, matched} = if nav =~ ~r/pricing/ and nav =~ ~r/docs|api|login/ do
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
    "ai" => {"AI & ML", 6},
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
    {~r/law firm|attorneys?\b|lawyers?\b|legal (?:services|practice|team)/i, "Consulting", 7},
    {~r/newsletter|weekly digest|daily brief|subscribe to (?:our|the)/i, "Newsletter", 5},
    {~r/marketplace|buy and sell|connect buyers/i, "Marketplace", 6},
    {~r/online course|bootcamp|online (?:learning|classes|school)/i, "Education", 5},
    {~r/calculator|generator|converter|checker|(?:free )?tool\b/i, "Tool", 6},
    {~r/community|forum|discussion|join (?:the |our )?community/i, "Community", 4},
    {~r/latest news|breaking news|editorial|journalism|reporting/i, "Media", 5},
    {~r/directory|listing|submit your|find (?:a |local )/i, "Directory", 4},
  ]

  # Industry patterns: {regex, industry, points}
  @industry_keywords [
    {~r/\bfintech\b|payment[s ]?(?:platform|solution|gateway)|banking|lending|mortgage|(?:invest|trading)\b|crypto(?:currency)?/i, "Fintech", 6},
    {~r/\bhipaa\b|telemedicine|telehealth|\behr\b|clinical|patient[s ]?(?:care|portal)|medical|healthcare/i, "Healthcare", 7},
    {~r/marketing (?:platform|software|tool|automation)|(?:\bseo\b|\bppc\b|\bcrm\b)|email marketing|lead gen/i, "Marketing", 6},
    {~r/\bhr\b software|recruiting|payroll|onboarding|\bats\b|applicant tracking|talent (?:management|acquisition)/i, "HR & Recruiting", 6},
    {~r/law firm|attorney|litigation|compliance|personal injury|legal (?:services|practice)/i, "Legal", 7},
    {~r/real estate|homes for sale|\bmls\b|realtor|property (?:management|listings?)/i, "Real Estate", 7},
    {~r/skincare|makeup|cosmetic[s]?|beauty|serum|moisturizer|salon/i, "Beauty", 6},
    {~r/fashion|apparel|clothing|footwear|jewelry|designer|boutique/i, "Fashion", 6},
    {~r/restaurant|bakery|coffee shop|gluten[- ]free|food (?:delivery|ordering)|catering|cuisine|brewery|winery|bistro|pizz/i, "Food & Beverage", 6},
    {~r/\bai[- ]powered\b|machine learning|\bgpt\b|\bllm\b|generative ai|artificial intelligence|neural net/i, "AI & ML", 6},
    {~r/developer[s ]?(?:tool|platform)|(?:\bsdk\b|\bapi\b|devops|ci\/cd)|kubernetes|docker|open[- ]?source/i, "DevTools", 6},
    {~r/cybersecurity|infosec|threat (?:detection|intelligence)|vulnerability|penetration test|\bsiem\b/i, "Security", 7},
    {~r/productivity|project management|task management|workflow|collaboration tool|team (?:management|communication)/i, "Productivity", 5},
    {~r/logistics|supply chain|shipping (?:software|platform)|fleet management|warehouse/i, "Logistics", 6},
    {~r/construction|contractor|building (?:materials|supplies)|manufacturing|industrial/i, "Construction & Manufacturing", 6},
    {~r/garden|landscaping|home (?:improvement|decor|renovation)|furniture|interior design/i, "Home & Garden", 5},
    {~r/data analytics|business intelligence|\bbi\b (?:tool|platform|solution)|data (?:visualization|warehouse|pipeline)/i, "Data & Analytics", 6},
    {~r/online (?:learning|education|school|university)|e-?learning|\blms\b|student|academic|curriculum/i, "Education", 5},
    {~r/hotel|travel (?:agency|booking)|tourism|vacation|flight|destination/i, "Travel", 6},
    {~r/streaming|entertainment|gaming|music|video|podcast|media (?:company|production)/i, "Media & Entertainment", 5},
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
      body_match = Regex.match?(regex, body)
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

  defp pick_winner(model_scores, industry_scores, methods) do
    model = winner(model_scores)
    industry = winner(industry_scores)
    model_pts = if model, do: Map.get(model_scores, model, 0), else: 0
    industry_pts = if industry, do: Map.get(industry_scores, industry, 0), else: 0
    best_pts = max(model_pts, industry_pts)

    # Winner ratio: use whichever dimension has the stronger signal
    {ratio_pts, ratio_total} = if model_pts >= industry_pts do
      {model_pts, Map.values(model_scores) |> Enum.sum() |> max(1)}
    else
      {industry_pts, Map.values(industry_scores) |> Enum.sum() |> max(1)}
    end
    ratio = ratio_pts / ratio_total

    # Confidence = blend of winner ratio + absolute score boost
    abs_boost = min(best_pts / 25.0, 1.0)
    confidence = Float.round((ratio * 0.5 + abs_boost * 0.5) |> min(0.99), 2)

    if confidence >= @min_confidence do
      %{
        business_model: model || "",
        industry: industry || "",
        confidence: confidence,
        method: methods |> Enum.reverse() |> Enum.uniq() |> Enum.join("+")
      }
    else
      @empty_result
    end
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
end
