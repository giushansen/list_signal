defmodule LS.HTTP.PageExtractor do
  @moduledoc """
  Extracts actionable pages and emails from homepage HTML.

  NOW WITH:
  - Built-in HTML cleaning (removes comments/styles for faster parsing)
  - Cloudflare email protection decoding
  - HTML entity decoding

  Outputs:
  - `http_pages`: Pricing, Contact, Docs, Login, Signup pages (pipe-separated)
  - `http_emails`: Email addresses including Cloudflare obfuscated (pipe-separated)

  Supports 9 languages: EN, FR, ES, ZH, DE, PT, JA, IT, NL
  """

  alias LS.HTTP.CloudflareEmailDecoder

  @max_pages 10
  @max_emails 10
  @max_body_scan 100_000

  # HTML cleaning regexes (merged from HTMLCleaner)
  @style_regex ~r/<style\b[^>]*>.*?<\/style>/is
  @comment_regex ~r/<!--.*?-->/s

  # Email extraction patterns
  @mailto_regex ~r/mailto:([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})/i
  @email_regex ~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/
  @obfuscated_at_dot_regex ~r/\b([A-Za-z0-9._%+-]+)\s*[\[\(]\s*@\s*[\]\)]\s*([A-Za-z0-9.-]+)\s*[\[\(]\s*\.\s*[\]\)]\s*([A-Za-z]{2,})\b/i
  @obfuscated_words_regex ~r/\b([A-Za-z0-9._%+-]+)\s+(?:AT|at|At)\s+([A-Za-z0-9.-]+)\s+(?:DOT|dot|Dot)\s+([A-Za-z]{2,})\b/
  @obfuscated_spaced_regex ~r/\b([A-Za-z0-9._%+-]+)\s+@\s+([A-Za-z0-9.-]+)\s+\.\s+([A-Za-z]{2,})\b/
  @obfuscated_curly_regex ~r/\b([A-Za-z0-9._%+-]+)\s*\{(?:at|@)\}\s*([A-Za-z0-9.-]+)\s*\{(?:dot|\.)\}\s*([A-Za-z]{2,})\b/i
  @html_entity_at_regex ~r/\b([A-Za-z0-9._%+-]+)(?:&#64;|&#x40;|&commat;)([A-Za-z0-9.-]+)(?:&#46;|&#x2e;|&period;)([A-Za-z]{2,})\b/i
  @data_attr_email_regex ~r/data-(?:email|mail|contact)=["']([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})["']/i
  @mailto_encoded_regex ~r/mailto:([A-Za-z0-9._%+-]+)%40([A-Za-z0-9.-]+)\.([A-Za-z]{2,})/i
  @js_concat_regex ~r/["']([A-Za-z0-9._%+-]+)["']\s*\+\s*["']@["']\s*\+\s*["']([A-Za-z0-9.-]+\.[A-Za-z]{2,})["']/
  @reversed_email_regex ~r/\b([a-z]{2,})\.([A-Za-z0-9.-]+)@([A-Za-z0-9._%+-]+)\b/

  @skip_email_patterns [
    ~r/^(noreply|no-reply|donotreply|do-not-reply)@/i,
    ~r/^(admin|webmaster|postmaster|hostmaster|root)@/i,
    ~r/^(abuse|spam|mailer-daemon|daemon)@/i,
    ~r/@example\.(com|org|net)$/i,
    ~r/@(localhost|test|invalid)$/i,
    ~r/\.(png|jpg|jpeg|gif|svg|css|js|ico)$/i,
    ~r/@sentry\.io$/i,
    ~r/@.*\.(wixsite|squarespace|webflow)\.com$/i,
    ~r/^(test|testing|sample|demo|example|fake)@/i
  ]

  @valid_tlds MapSet.new([
    "com", "org", "net", "edu", "gov", "io", "co", "ai", "app", "dev",
    "tech", "cloud", "biz", "info", "uk", "de", "fr", "es", "it", "nl",
    "be", "ch", "at", "au", "nz", "ca", "us", "br", "mx", "jp", "cn",
    "kr", "sg", "hk", "tw", "in", "ru", "pl", "se", "no", "dk", "fi",
    "ie", "pt", "co.uk", "com.au", "co.nz", "com.br", "co.jp", "com.cn",
    "co.kr", "com.sg"
  ])

  @href_regex ~r/href=["']([^"']+)["']/i

  # ============================================================================
  # PAGE PATTERNS - BUILT AT COMPILE TIME
  # ============================================================================

  # Pricing patterns
  @pricing_patterns_en [
    "/pricing", "/price", "/prices", "/plan", "/plans",
    "/pricing.html", "/prices.html", "/pricing-plans",
    "/packages", "/package", "/tiers", "/tier", "/editions",
    "/subscribe", "/subscription", "/membership",
    "/buy", "/purchase", "/order", "/checkout",
    "/enterprise", "/business", "/teams", "/corporate",
    "/pro", "/premium", "/plus", "/professional", "/starter", "/upgrade",
    "/products", "/solutions", "/billing", "/payment", "/licenses",
    "/compare", "/comparison"
  ]

  @pricing_patterns_fr [
    "/tarifs", "/tarif", "/prix", "/nos-prix", "/nos-tarifs",
    "/grille-tarifaire", "/forfaits", "/forfait", "/formules",
    "/abonnement", "/abonnements", "/acheter", "/achat", "/commander",
    "/entreprise", "/professionnels", "/offres", "/offre"
  ]

  @pricing_patterns_es [
    "/precios", "/precio", "/tarifas", "/tarifa", "/planes", "/plan",
    "/paquetes", "/paquete", "/suscripcion", "/membresia", "/comprar",
    "/compra", "/empresa", "/empresas", "/corporativo", "/productos", "/servicios"
  ]

  @pricing_patterns_zh [
    "/jiage", "/price-cn", "/pricing-cn", "/fangan", "/taocan",
    "/dingyue", "/huiyuan", "/vip", "/goumai", "/qiye", "/tuandui",
    "/chanpin", "/fuwu"
  ]

  @pricing_patterns_de [
    "/preise", "/preis", "/preisliste", "/tarife", "/pakete", "/paket",
    "/abonnement", "/abo", "/kaufen", "/bestellen", "/unternehmen",
    "/produkte", "/loesungen"
  ]

  @pricing_patterns_pt [
    "/precos", "/preco", "/planos", "/plano", "/pacotes", "/pacote",
    "/assinatura", "/comprar", "/empresas", "/produtos", "/servicos"
  ]

  @pricing_patterns_ja [
    "/kakaku", "/price-jp", "/pricing-jp", "/puran", "/plan-jp",
    "/kounyu", "/kounyuu", "/kigyou", "/kigyo"
  ]

  @pricing_patterns_it [
    "/prezzi", "/prezzo", "/piani", "/piano", "/pacchetti", "/pacchetto",
    "/abbonamento", "/acquista", "/aziende", "/prodotti"
  ]

  @pricing_patterns_nl [
    "/prijzen", "/prijs", "/pakketten", "/pakket", "/plannen", "/plan",
    "/abonnement", "/kopen", "/bedrijven", "/producten"
  ]

  # Contact patterns
  @contact_patterns_en [
    "/contact", "/contact-us", "/get-in-touch", "/reach-us",
    "/support", "/help", "/feedback", "/inquiry", "/sales", "/demo"
  ]

  @contact_patterns_fr [
    "/contact", "/contactez-nous", "/nous-contacter", "/support",
    "/aide", "/commercial", "/demo"
  ]

  @contact_patterns_es [
    "/contacto", "/contactenos", "/soporte", "/ayuda", "/ventas", "/demo"
  ]

  @contact_patterns_zh [
    "/lianxi", "/contact-cn", "/kefu", "/fuwu", "/zhichi",
    "/support-cn", "/bangzhu"
  ]

  @contact_patterns_de [
    "/kontakt", "/kontaktieren", "/support", "/hilfe", "/vertrieb", "/demo"
  ]

  @contact_patterns_pt [
    "/contato", "/fale-conosco", "/suporte", "/ajuda", "/vendas", "/demo"
  ]

  @contact_patterns_ja [
    "/toiawase", "/contact-jp", "/supoto", "/support-jp", "/eigyou"
  ]

  @contact_patterns_it [
    "/contatti", "/contattaci", "/supporto", "/aiuto", "/vendite", "/demo"
  ]

  @contact_patterns_nl [
    "/contact", "/neem-contact-op", "/ondersteuning", "/hulp",
    "/verkoop", "/demo"
  ]

  # Other patterns
  @signup_patterns_en [
    "/signup", "/sign-up", "/register", "/join", "/get-started",
    "/start", "/create-account", "/free-trial", "/trial"
  ]

  @docs_patterns_en [
    "/docs", "/documentation", "/api", "/developers", "/guides",
    "/wiki", "/knowledge", "/faq"
  ]

  @login_patterns_en [
    "/login", "/sign-in", "/signin", "/log-in", "/auth",
    "/account", "/dashboard", "/portal"
  ]

  # ============================================================================
  # COMBINED PATTERNS - BUILT ONCE AT COMPILE TIME
  # ============================================================================

  # Build combined pricing patterns ONCE
  @all_pricing_patterns (
    @pricing_patterns_en ++ @pricing_patterns_fr ++ @pricing_patterns_es ++
    @pricing_patterns_zh ++ @pricing_patterns_de ++ @pricing_patterns_pt ++
    @pricing_patterns_ja ++ @pricing_patterns_it ++ @pricing_patterns_nl
  )

  # Build combined contact patterns ONCE
  @all_contact_patterns (
    @contact_patterns_en ++ @contact_patterns_fr ++ @contact_patterns_es ++
    @contact_patterns_zh ++ @contact_patterns_de ++ @contact_patterns_pt ++
    @contact_patterns_ja ++ @contact_patterns_it ++ @contact_patterns_nl
  )

  # Build ALL page patterns ONCE
  @all_page_patterns (
    @all_pricing_patterns ++ @all_contact_patterns ++
    @signup_patterns_en ++ @docs_patterns_en ++ @login_patterns_en
  )

  # Build MapSets ONCE using pre-combined lists
  @page_set MapSet.new(@all_page_patterns)
  @pricing_set MapSet.new(@all_pricing_patterns)
  @contact_set MapSet.new(@all_contact_patterns)
  @signup_set MapSet.new(@signup_patterns_en)
  @login_set MapSet.new(@login_patterns_en)
  @docs_set MapSet.new(@docs_patterns_en)

  # ===========================================================================
  # PUBLIC API
  # ===========================================================================

  @doc """
  Extract both pages and emails in one pass.
  Automatically cleans HTML (removes comments/styles) for faster parsing.
  Returns {pages_string, emails_string} tuple.
  """
  def extract_all(body, domain \\ nil)

  def extract_all(body, domain) when is_binary(body) do
    # Clean HTML first (merged from HTMLCleaner)
    clean_body = clean_html(body)

    {extract_pages(clean_body, domain), extract_emails(clean_body)}
  end

  def extract_all(_, _), do: {nil, nil}

  @doc """
  Extract actionable pages from HTML.
  """
  def extract_pages(body, domain \\ nil)

  def extract_pages(body, domain) when is_binary(body) do
    body_to_scan = limit_body(body)
    body_lower = String.downcase(body_to_scan)
    domain_lower = if domain, do: String.downcase(domain), else: nil

    pages =
      body_lower
      |> extract_hrefs(domain_lower)
      |> Enum.uniq()
      |> Enum.filter(&actionable_page?/1)
      |> normalize_paths()
      |> Enum.uniq()
      |> Enum.take(@max_pages)

    case pages do
      [] -> nil
      paths -> Enum.join(paths, "|")
    end
  rescue
    _ -> nil
  end

  def extract_pages(_, _), do: nil

  @doc """
  Extract email addresses from HTML, including Cloudflare obfuscation.
  """
  def extract_emails(body) when is_binary(body) do
    body_to_scan = limit_body(body)

    emails =
      []
      # Cloudflare Email Protection (XOR cipher)
      |> Kernel.++(CloudflareEmailDecoder.extract_all(body_to_scan))
      # Existing patterns
      |> Kernel.++(extract_mailto_emails(body_to_scan))
      |> Kernel.++(extract_mailto_encoded_emails(body_to_scan))
      |> Kernel.++(extract_data_attr_emails(body_to_scan))
      |> Kernel.++(extract_raw_emails(body_to_scan))
      |> Kernel.++(extract_obfuscated_at_dot(body_to_scan))
      |> Kernel.++(extract_obfuscated_words(body_to_scan))
      |> Kernel.++(extract_obfuscated_spaced(body_to_scan))
      |> Kernel.++(extract_obfuscated_curly(body_to_scan))
      |> Kernel.++(extract_html_entity_emails(body_to_scan))
      |> Kernel.++(extract_js_concat_emails(body_to_scan))
      |> Kernel.++(extract_reversed_emails(body_to_scan))
      |> Enum.map(&String.downcase/1)
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()
      |> Enum.reject(&skip_email?/1)
      |> Enum.filter(&valid_email?/1)
      |> Enum.take(@max_emails)

    case emails do
      [] -> nil
      list -> Enum.join(list, "|")
    end
  rescue
    _ -> nil
  end

  def extract_emails(_), do: nil

  # ===========================================================================
  # PRIVATE - HTML CLEANING (merged from HTMLCleaner)
  # ===========================================================================

  defp clean_html(html) when is_binary(html) do
    html
    |> String.replace(@style_regex, " ")
    |> String.replace(@comment_regex, " ")
    |> String.slice(0, 300_000)  # Cap at 300KB
  end

  defp clean_html(_), do: ""

  # ===========================================================================
  # PRIVATE - EMAIL EXTRACTION
  # ===========================================================================

  defp extract_mailto_emails(body) do
    @mailto_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
  rescue
    _ -> []
  end

  defp extract_mailto_encoded_emails(body) do
    @mailto_encoded_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain, tld] -> "#{name}@#{domain}.#{tld}" end)
  rescue
    _ -> []
  end

  defp extract_data_attr_emails(body) do
    @data_attr_email_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
  rescue
    _ -> []
  end

  defp extract_raw_emails(body) do
    @email_regex
    |> Regex.scan(body)
    |> List.flatten()
  rescue
    _ -> []
  end

  defp extract_obfuscated_at_dot(body) do
    @obfuscated_at_dot_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain, tld] -> "#{name}@#{domain}.#{tld}" end)
  rescue
    _ -> []
  end

  defp extract_obfuscated_words(body) do
    @obfuscated_words_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain, tld] -> "#{name}@#{domain}.#{tld}" end)
  rescue
    _ -> []
  end

  defp extract_obfuscated_spaced(body) do
    @obfuscated_spaced_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain, tld] -> "#{name}@#{domain}.#{tld}" end)
  rescue
    _ -> []
  end

  defp extract_obfuscated_curly(body) do
    @obfuscated_curly_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain, tld] -> "#{name}@#{domain}.#{tld}" end)
  rescue
    _ -> []
  end

  defp extract_html_entity_emails(body) do
    @html_entity_at_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain, tld] -> "#{name}@#{domain}.#{tld}" end)
  rescue
    _ -> []
  end

  defp extract_js_concat_emails(body) do
    @js_concat_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [name, domain_tld] -> "#{name}@#{domain_tld}" end)
  rescue
    _ -> []
  end

  defp extract_reversed_emails(body) do
    if String.contains?(body, "direction:rtl") or String.contains?(body, "data-reverse") do
      @reversed_email_regex
      |> Regex.scan(body, capture: :all_but_first)
      |> Enum.map(fn [tld, domain, name] ->
        "#{String.reverse(name)}@#{String.reverse(domain)}.#{String.reverse(tld)}"
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp skip_email?(email) do
    Enum.any?(@skip_email_patterns, fn pattern ->
      Regex.match?(pattern, email)
    end)
  end

  defp valid_email?(email) do
    case String.split(email, "@") do
      [name, domain] when byte_size(name) > 0 and byte_size(domain) > 2 ->
        tld = domain |> String.split(".") |> List.last() |> String.downcase()
        MapSet.member?(@valid_tlds, tld)
      _ ->
        false
    end
  rescue
    _ -> false
  end

  # ===========================================================================
  # PRIVATE - PAGE EXTRACTION
  # ===========================================================================

  defp extract_hrefs(body_lower, domain) do
    @href_regex
    |> Regex.scan(body_lower, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(fn href -> extract_path(href, domain) end)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp extract_path(href, domain) when is_binary(href) do
    cond do
      href == "" or String.starts_with?(href, "#") -> nil
      String.starts_with?(href, "//") -> nil
      String.starts_with?(href, "mailto:") or String.starts_with?(href, "tel:") or String.starts_with?(href, "javascript:") or String.starts_with?(href, "data:") -> nil
      String.starts_with?(href, "/") -> href
      domain != nil and is_same_domain_url?(href, domain) -> extract_path_from_url(href)
      String.starts_with?(href, "http://") or String.starts_with?(href, "https://") -> nil
      not String.contains?(href, ":") -> "/" <> href
      true -> nil
    end
  end

  defp extract_path(_href, _domain), do: nil

  defp is_same_domain_url?(href, domain) do
    String.starts_with?(href, "https://#{domain}") or String.starts_with?(href, "http://#{domain}") or String.starts_with?(href, "https://www.#{domain}") or String.starts_with?(href, "http://www.#{domain}")
  end

  defp extract_path_from_url(url) do
    case URI.parse(url) do
      %URI{path: path} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp actionable_page?(path) when is_binary(path) do
    normalized = normalize_single_path(path)
    MapSet.member?(@page_set, normalized) or MapSet.member?(@page_set, String.trim_trailing(normalized, "/")) or Enum.any?(@all_page_patterns, fn pattern -> String.starts_with?(normalized, pattern <> "/") or String.starts_with?(normalized, pattern <> "?") end)
  end

  defp actionable_page?(_), do: false

  defp normalize_single_path(path) do
    path
    |> String.downcase()
    |> ensure_leading_slash()
    |> remove_query_and_fragment()
    |> String.trim_trailing("/")
    |> then(fn p -> if p == "", do: "/", else: p end)
  end

  defp normalize_paths(paths) do
    paths
    |> Enum.map(&normalize_single_path/1)
    |> Enum.uniq()
    |> Enum.sort_by(&page_priority/1)
  end

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path

  defp remove_query_and_fragment(path) do
    path
    |> String.split("?")
    |> List.first()
    |> String.split("#")
    |> List.first()
  end

  defp page_priority(path) do
    cond do
      MapSet.member?(@pricing_set, path) -> 0
      MapSet.member?(@contact_set, path) -> 1
      MapSet.member?(@signup_set, path) -> 2
      MapSet.member?(@login_set, path) -> 3
      MapSet.member?(@docs_set, path) -> 4
      true -> 5
    end
  end

  defp limit_body(body) do
    body
    |> extract_body_content()
    |> limit_size()
  end

  defp extract_body_content(html) do
    case Regex.run(~r/<body[^>]*>(.*)/is, html, capture: :all_but_first) do
      [body_content] -> body_content
      _ -> html
    end
  rescue
    _ -> html
  end

  defp limit_size(body) when byte_size(body) > @max_body_scan do
    binary_part(body, 0, @max_body_scan)
  end

  defp limit_size(body), do: body
end
