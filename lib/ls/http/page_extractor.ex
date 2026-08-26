defmodule LS.HTTP.PageExtractor do
  @moduledoc """
  Extracts actionable pages and emails from homepage HTML.

  NOW WITH:
  - Built-in HTML cleaning (removes comments/styles for faster parsing)
  - Cloudflare email protection decoding
  - HTML entity decoding

  Outputs:
  - `http_pages`: Pricing, Contact, Legal, About, Career, Docs, Login, Signup
    pages (pipe-separated)
  - `http_emails`: Email addresses including Cloudflare obfuscated (pipe-separated)

  Supports 9 languages: EN, FR, ES, ZH, DE, PT, JA, IT, NL

  ## What gets scanned

  Not the whole document: a bounded window of capped `<head>` + the start of
  the body + the END of the body. Emails and imprint links both live in the
  footer, so the tail slice is load-bearing — see `@head_scan` for the
  measurement behind the bounds.

  ## What this does NOT do

  It does not check that an address belongs to the site it was found on.
  Imprint pages in particular carry third-party addresses — the agency that
  built the site, the host, statutory arbitration boards — so a caller that
  needs "this business's own email" must filter to the domain itself.
  """

  alias LS.HTTP.CloudflareEmailDecoder

  # Raised from 10 to 14 (2026-08-26) when :legal and :about were added —
  # eight kinds at two slots each no longer fit in ten, and the kinds that
  # sort last are exactly the contact-bearing ones.
  @max_pages 14
  @max_emails 10

  # Scan window (2026-08-26). The old rule was "first 100KB of <body>, drop
  # <head>", and it lost emails two separate ways:
  #
  #   1. <head> was discarded outright, so every JSON-LD schema.org
  #      ContactPoint address was invisible — the highest-precision source
  #      there is, because the site *declares* the address as its own.
  #   2. Only the FIRST 100KB of the body was read. Emails and the imprint
  #      link both live in the footer, which is at the end. 57% of sampled
  #      homepages are larger than 100KB (mean 187KB, p95 608KB), so on the
  #      majority of pages the footer was never scanned. Measured example:
  #      busemann-gmbh.de carries its address at byte 336,885 of 362KB.
  #
  # Measured on 393 real homepages (71.8MB, mean 186KB, p95 608KB, max 2.4MB),
  # counting domains that yield at least one on-domain address. Percentages
  # are of the maximum an uncapped scan achieves:
  #
  #     old: body[:100k], no head          74.8%     61 KB scanned/page
  #     + head only                        81.9%     63 KB
  #     head + body[:300k]                 95.3%     98 KB
  #     head + body[:100k] + body[-100k:]  96.1%     85 KB   <- chosen
  #     head + body[:150k] + body[-150k:]  97.6%     98 KB
  #     head + full body                  100.0%    126 KB
  #
  # A window beats a plain prefix at equal cost (96.1% for 85KB vs 95.3% for
  # 98KB) because what is missing sits at the end, not in the middle.
  #
  # 100k/100k rather than 150k/150k is a deliberate resource trade. Per-page
  # peak process heap, measured one isolated process per page as production
  # runs them:
  #
  #                     median      p95       max
  #     old            2,628 KB  10,578 KB  11,213 KB
  #     100k/100k      2,528 KB  11,055 KB  15,091 KB   <- chosen
  #     150k/150k      2,192 KB  12,897 KB  20,755 KB
  #
  # 150k buys 4 more domains out of 393 and costs +85% peak heap and -11%
  # throughput; 100k costs +35% peak and -2%. At HTTP concurrency 100 that is
  # ~1.5GB worst case instead of ~2.1GB, which matters on the 1-core nodes and
  # given this fleet's OOM history. Median heap actually IMPROVES on both,
  # because clean_html/1 now runs over a bounded window instead of a document
  # that reaches 2.4MB.
  @head_scan 32_000
  @body_head_scan 100_000
  @body_tail_scan 100_000

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

  # Careers. Added 2026-07-28: these were missing entirely, so only 2,213 of
  # 6.36M businesses had a careers path recorded and the jobs enrichment had
  # nothing to visit. Multi-language because hiring pages are rarely English-
  # only on EU domains.
  @career_patterns [
    "/careers", "/career", "/jobs", "/job", "/join-us", "/join",
    "/work-with-us", "/we-are-hiring", "/hiring", "/opportunities",
    "/emplois", "/carrieres", "/recrutement", "/nous-rejoindre",
    "/empleo", "/trabaja-con-nosotros", "/carreras",
    "/karriere", "/stellenangebote", "/jobsuche",
    "/carriere", "/lavora-con-noi", "/vagas", "/carreiras",
    "/vacatures", "/werken-bij"
  ]

  # Legal / imprint pages. Added 2026-08-26: these were missing entirely, and
  # in the EU they are the single highest-yield page for a contact address —
  # §5 DDG (DE) and the LCEN (FR) *require* a reachable email there, whereas
  # /kontakt is usually only a form. Measured on 117 German business domains
  # that ListSignal recorded as having no email at all: 60% of the addresses
  # recoverable from a second page came from /impressum, and only 22% from the
  # /kontakt and /contact paths already in the list.
  #
  # Kept deliberately narrow. Paths like /legal, /terms and /privacy match
  # policy documents that carry a controller's address on nearly every site,
  # which would attribute a law firm's or a parent company's mailbox to the
  # business. Only the statutory imprint pages belong here.
  @legal_patterns [
    "/impressum", "/imprint", "/impressum.html", "/impressum.php",
    "/mentions-legales", "/mentions-legales.html", "/mentionslegales",
    "/aviso-legal", "/avis-legal", "/note-legali", "/legal-notice",
    "/colofon", "/juridische-informatie", "/rechtliches",
    "/informacion-legal", "/informativa-legale"
  ]

  # About / team pages. Added 2026-08-26 alongside the legal patterns: 13% of
  # the second-page yield in the same measurement came from /about and /team,
  # and these are the only page type that routinely carries a *named person's*
  # address rather than a role mailbox.
  @about_patterns [
    "/about", "/about-us", "/aboutus", "/who-we-are", "/our-story",
    "/team", "/our-team", "/meet-the-team", "/people", "/staff",
    "/a-propos", "/qui-sommes-nous", "/notre-equipe", "/equipe",
    "/ueber-uns", "/uber-uns", "/unternehmen", "/das-team",
    "/sobre-nosotros", "/quienes-somos", "/nosotros", "/equipo",
    "/chi-siamo", "/il-team", "/sobre-nos", "/quem-somos",
    "/over-ons", "/ons-team"
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
    @signup_patterns_en ++ @docs_patterns_en ++ @login_patterns_en ++
    @career_patterns ++ @legal_patterns ++ @about_patterns
  )

  # Build MapSets ONCE using pre-combined lists
  @page_set MapSet.new(@all_page_patterns)
  @pricing_set MapSet.new(@all_pricing_patterns)
  @contact_set MapSet.new(@all_contact_patterns)
  @signup_set MapSet.new(@signup_patterns_en)
  @login_set MapSet.new(@login_patterns_en)
  @docs_set MapSet.new(@docs_patterns_en)
  @career_set MapSet.new(@career_patterns)
  @legal_set MapSet.new(@legal_patterns)
  @about_set MapSet.new(@about_patterns)

  @doc """
  Classify a path recorded in `http_pages` into the kind of page it is.

  **Single source of truth for both pipelines**: discovery records the paths
  here, and the enrichment pipeline asks this function which ones are worth a
  visit — so the two can never disagree about what "the pricing page" means.

      iex> LS.HTTP.PageExtractor.page_kind("/contactez-nous")
      :contact
      iex> LS.HTTP.PageExtractor.page_kind("/blog")
      nil
  """
  @spec page_kind(String.t()) ::
          :contact | :legal | :about | :pricing | :career | :login | :signup | :docs | nil
  def page_kind(path) when is_binary(path) do
    p = String.downcase(path)

    cond do
      MapSet.member?(@contact_set, p) -> :contact
      MapSet.member?(@legal_set, p) -> :legal
      legal_stem?(p) -> :legal
      MapSet.member?(@about_set, p) -> :about
      MapSet.member?(@pricing_set, p) -> :pricing
      MapSet.member?(@career_set, p) -> :career
      MapSet.member?(@login_set, p) -> :login
      MapSet.member?(@signup_set, p) -> :signup
      MapSet.member?(@docs_set, p) -> :docs
      true -> nil
    end
  end

  def page_kind(_), do: nil

  # Imprint pages are routinely nested or suffixed, and an exact-path list
  # cannot keep up: Shopify puts them at /pages/impressum, localised sites at
  # /de/impressum, and hand-built sites at /impressum-rechtliche-hinweise.html.
  # Matching the LAST path segment by stem recovered 5 of the 10 German
  # domains still missed after the exact list was added (2026-08-26).
  #
  # Safe to stem-match precisely because these words are unambiguous: a page
  # whose final segment begins with "impressum" is an imprint page and nothing
  # else. Deliberately NOT extended to /legal, /terms or /privacy, which name
  # policy documents that carry a third party's address on most sites.
  @legal_stems ["impressum", "imprint", "mentions-legales", "mentionslegales",
                "aviso-legal", "legal-notice", "note-legali"]

  defp legal_stem?(path) do
    last = path |> String.split("/", trim: true) |> List.last()
    is_binary(last) and Enum.any?(@legal_stems, &String.starts_with?(last, &1))
  end

  @doc """
  Pick the paths worth a browser visit from a stored `http_pages` string,
  at most one per kind (visiting five contact-page variants is waste).

      LS.HTTP.PageExtractor.pages_to_visit("/contact|/pricing|/blog")
      #=> [contact: "/contact", pricing: "/pricing"]
  """
  @spec pages_to_visit(String.t() | nil, [atom()]) :: [{atom(), String.t()}]
  # :login is deliberately ABSENT from the default. The enrichment lane fetched
  # it for months and never read the HTML — `html_of(visited, :login)` is not
  # called anywhere — so it was one wasted request per domain. Login-page tech
  # detection genuinely happens, but in DISCOVERY
  # (`LS.Pipeline.enhance_with_secondary_pages/3`), which fetches /login and
  # unions the result into `http_tech`. Removing it here pays for most of the
  # cost of adding :legal and :about (2026-08-26).
  def pages_to_visit(pages, kinds \\ [:contact, :legal, :about, :pricing, :career])

  def pages_to_visit(pages, kinds) when is_binary(pages) and pages != "" do
    pages
    |> String.split("|", trim: true)
    |> Enum.reduce(%{}, fn path, acc ->
      kind = page_kind(path)
      if kind in kinds and not Map.has_key?(acc, kind), do: Map.put(acc, kind, path), else: acc
    end)
    |> Enum.sort_by(fn {kind, _} -> Enum.find_index(kinds, &(&1 == kind)) end)
  end

  def pages_to_visit(_, _), do: []

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
    # Window and clean ONCE, then run both extractors over the same buffer.
    scan = prepare(body)

    {do_extract_pages(scan, domain), do_extract_emails(scan)}
  end

  def extract_all(_, _), do: {nil, nil}

  @doc """
  Extract actionable pages from HTML.
  """
  def extract_pages(body, domain \\ nil)

  def extract_pages(body, domain) when is_binary(body), do: do_extract_pages(prepare(body), domain)
  def extract_pages(_, _), do: nil

  defp do_extract_pages(body_to_scan, domain) do
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

  @doc """
  Extract email addresses from HTML, including Cloudflare obfuscation.
  """
  def extract_emails(body) when is_binary(body), do: do_extract_emails(prepare(body))
  def extract_emails(_), do: nil

  defp do_extract_emails(body_to_scan) do
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

  # ===========================================================================
  # PRIVATE - HTML CLEANING (merged from HTMLCleaner)
  # ===========================================================================

  # Window FIRST, then clean. The other order truncated the raw document to
  # 300KB before the footer was ever selected, which put back exactly the bug
  # the window exists to fix. Cleaning also gets ~7x cheaper: two regex passes
  # over a bounded ~332KB buffer instead of over a document that reaches 2.4MB.
  defp prepare(html) when is_binary(html), do: html |> limit_body() |> clean_html()
  defp prepare(_), do: ""

  defp clean_html(html) when is_binary(html) do
    html
    |> String.replace(@style_regex, " ")
    |> String.replace(@comment_regex, " ")
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
    MapSet.member?(@page_set, normalized) or MapSet.member?(@page_set, String.trim_trailing(normalized, "/")) or legal_stem?(normalized) or Enum.any?(@all_page_patterns, fn pattern -> String.starts_with?(normalized, pattern <> "/") or String.starts_with?(normalized, pattern <> "?") end)
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
    |> cap_per_kind()
  end

  # Keep at most two paths per kind before @max_pages truncates. Sorting by
  # priority is not sufficient on its own: a shop with fourteen /products and
  # /solutions links fills every slot with one kind, and the enrichment lane
  # loses the page it actually needed. Two, not one, because the first match
  # is sometimes a redirect stub or a language-root variant.
  @per_kind_limit 2

  defp cap_per_kind(paths) do
    paths
    |> Enum.reduce({[], %{}}, fn path, {kept, counts} ->
      kind = page_kind(path) || :other
      n = Map.get(counts, kind, 0)

      if n < @per_kind_limit,
        do: {[path | kept], Map.put(counts, kind, n + 1)},
        else: {kept, counts}
    end)
    |> elem(0)
    |> Enum.reverse()
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

  # Ordered by how likely the page is to carry a contact address, because
  # @max_pages truncates and whatever sorts last is simply lost.
  #
  # 2026-08-26: legal/about/career used to share the catch-all bucket, so a
  # site with a dozen pricing links pushed its /impressum out of http_pages
  # entirely and the enrichment lane never saw it — only 4.3% of homepages
  # recorded a legal link before this was fixed. Priority alone is not enough
  # either; see cap_per_kind/1.
  defp page_priority(path) do
    cond do
      MapSet.member?(@legal_set, path) -> 0
      MapSet.member?(@contact_set, path) -> 1
      MapSet.member?(@about_set, path) -> 2
      MapSet.member?(@pricing_set, path) -> 3
      MapSet.member?(@career_set, path) -> 4
      MapSet.member?(@signup_set, path) -> 5
      MapSet.member?(@login_set, path) -> 6
      MapSet.member?(@docs_set, path) -> 7
      true -> 8
    end
  end

  # Build the bounded scan buffer: capped <head>, then the start of the body,
  # then the END of the body (the footer). See @head_scan for the measurement
  # that picked these bounds.
  #
  # Idempotent: re-running this on its own output is a no-op, because the
  # output carries no <body> tag and is already under the caps. That matters
  # because extract_pages/2 and extract_emails/1 are public and window their
  # own input, while extract_all/2 windows once and passes the result to both.
  defp limit_body(html) do
    {head, body} = split_head_body(html)
    head_part = head |> utf8_take(@head_scan) |> drop_dangling_open()

    cond do
      byte_size(body) <= @body_head_scan + @body_tail_scan ->
        join(head_part, body)

      true ->
        # Two slices with a separator between them, so a regex can never match
        # across the seam and invent an address out of two unrelated halves.
        prefix = body |> utf8_take(@body_head_scan) |> drop_dangling_open()
        suffix = body |> utf8_take_last(@body_tail_scan) |> drop_orphan_close()
        join(head_part, prefix <> "\n \n" <> suffix)
    end
  rescue
    _ -> html
  end

  # Slicing at a byte offset can land INSIDE a <style> or <script> block, and
  # that is not a cosmetic problem: clean_html/1 then sees an opening tag with
  # no closer in the slice, and `<style\b[^>]*>.*?</style>` happily matches
  # from that orphan to the next closer far away — deleting every link and
  # address in between.
  #
  # Measured when this was introduced (2026-08-26): institut-ziemer.de has
  # 246KB of inline CSS in seven blocks; the head cut landed mid-block and
  # clean_html collapsed the 118KB window to 16KB, taking the /impressum link
  # with it. Both halves of every slice therefore get balanced here.
  @block_tags ["<style", "<STYLE", "<script", "<SCRIPT"]
  @block_closers ["</style>", "</STYLE>", "</script>", "</SCRIPT>"]

  defp drop_dangling_open(bin) do
    case last_match(bin, @block_tags) do
      nil ->
        bin

      pos ->
        rest = binary_part(bin, pos, byte_size(bin) - pos)
        if closer?(rest), do: bin, else: binary_part(bin, 0, pos)
    end
  end

  defp drop_orphan_close(bin) do
    case :binary.match(bin, @block_closers) do
      :nomatch ->
        bin

      {pos, len} ->
        opener_before? =
          bin |> binary_part(0, pos) |> :binary.match(@block_tags) != :nomatch

        if opener_before? do
          bin
        else
          from = pos + len
          binary_part(bin, from, byte_size(bin) - from)
        end
    end
  end

  defp closer?(bin), do: :binary.match(bin, @block_closers) != :nomatch

  defp last_match(bin, patterns) do
    case :binary.matches(bin, patterns) do
      [] -> nil
      list -> list |> List.last() |> elem(0)
    end
  end

  # Byte-offset slicing on UTF-8 is a trap: cutting mid-codepoint yields an
  # invalid binary, and the very next String.downcase/1 raises. Every caller
  # here is wrapped in `rescue _ -> nil`, so the failure is SILENT — the page
  # simply reports no emails and no pages.
  #
  # This is why the cut is walked back to a codepoint boundary. Any page with
  # an accented character near the cut was affected, which on European sites
  # is most of them.
  defp utf8_take(bin, max) when byte_size(bin) <= max, do: bin

  defp utf8_take(bin, max) do
    # A UTF-8 sequence is at most 4 bytes, so at most 3 need dropping.
    Enum.reduce_while(0..3, binary_part(bin, 0, max), fn drop, _acc ->
      candidate = binary_part(bin, 0, max - drop)
      if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, candidate}
    end)
  end

  defp utf8_take_last(bin, max) when byte_size(bin) <= max, do: bin

  defp utf8_take_last(bin, max) do
    size = byte_size(bin)

    Enum.reduce_while(0..3, binary_part(bin, size - max, max), fn drop, _acc ->
      candidate = binary_part(bin, size - max + drop, max - drop)
      if String.valid?(candidate), do: {:halt, candidate}, else: {:cont, candidate}
    end)
  end

  defp join("", body), do: body
  defp join(head, body), do: head <> "\n \n" <> body

  defp split_head_body(html) do
    case :binary.match(html, ["<body", "<BODY", "<Body"]) do
      {start, _len} ->
        case :binary.match(binary_part(html, start, byte_size(html) - start), [">"]) do
          {off, _} ->
            open_end = start + off + 1
            {binary_part(html, 0, start),
             binary_part(html, open_end, byte_size(html) - open_end)}

          :nomatch ->
            {"", html}
        end

      :nomatch ->
        # No <body> tag at all (fragments, JSON-LD-only responses, malformed
        # markup). Treat the whole document as body rather than dropping it.
        {"", html}
    end
  rescue
    _ -> {"", html}
  end

end
