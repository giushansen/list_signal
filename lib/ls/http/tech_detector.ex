defmodule LS.HTTP.TechDetector do
  @moduledoc """
  HTTP technology detection - ZONE-BASED, UTF-8 safe, never crashes.

  Instead of matching signatures against the full HTML body (which matches
  "remember" → Ember, "solid foundation" → SolidJS, "spring sale" → Spring),
  we extract only TECHNICAL ZONES from the HTML:

  1. <script src="..."> URLs       → most reliable signal
  2. <link href="..."> URLs        → CSS, fonts, preloads
  3. Inline <script>...</script>   → JS code, configs, init calls
  4. <meta> tags                   → generator, og tags, configs
  5. HTML data-* attributes        → data-react, data-v-, ng-version
  6. HTTP response headers         → Server, X-Powered-By, Set-Cookie

  Visible text (paragraphs, headings, marketing copy) is EXCLUDED.
  """

  @doc """
  Detect technologies from HTTP response.
  Returns %{tech: [...], tools: [...], cdn: "...", blocked: "...", http_is_js_site: bool}
  """
  def detect(response) do
    body = safe_scrub(response.body)
    headers = response.headers

    # Extract ONLY technical zones from HTML (not visible text)
    tech_zone = extract_tech_zone(body)

    # Match signatures against technical zones + headers
    tech_data = LS.Signatures.detect_http_tech(tech_zone, headers)

    body_lower = String.downcase(body)
    Map.put(tech_data, :http_is_js_site, is_javascript_site(body_lower))
  end

  # ============================================================================
  # TECHNICAL ZONE EXTRACTION
  # ============================================================================

  @doc """
  Extract technical content from HTML, excluding visible text.
  Returns a single lowercased string containing only technical signals.
  """
  def extract_tech_zone(body) when is_binary(body) do
    [
      extract_script_srcs(body),
      extract_link_hrefs(body),
      extract_inline_scripts(body),
      extract_meta_tags(body),
      extract_html_attributes(body)
    ]
    |> Enum.join("\n")
    |> String.downcase()
  rescue
    _ -> ""
  end

  def extract_tech_zone(_), do: ""

  # All <script src="..."> URLs - THE most reliable signal
  defp extract_script_srcs(body) do
    ~r/<script[^>]*\bsrc\s*=\s*["']([^"']+)["']/is
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.join("\n")
  rescue
    _ -> ""
  end

  # All <link href="..."> URLs (CSS, fonts, preloads, icons)
  defp extract_link_hrefs(body) do
    ~r/<link[^>]*\bhref\s*=\s*["']([^"']+)["']/is
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.join("\n")
  rescue
    _ -> ""
  end

  # Inline <script>...</script> content (JS code, NOT visible text)
  # This catches gtag(), fbq(), analytics init, config objects etc.
  defp extract_inline_scripts(body) do
    ~r/<script(?:\s[^>]*)?>([^<]*(?:<(?!\/script>)[^<]*)*)<\/script>/is
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.reject(fn content ->
      String.trim(content) == "" or byte_size(String.trim(content)) < 5
    end)
    |> Enum.join("\n")
  rescue
    _ -> ""
  end

  # All <meta ...> tags (generator, og:, twitter:, etc.)
  defp extract_meta_tags(body) do
    ~r/<meta\s[^>]*>/is
    |> Regex.scan(body)
    |> List.flatten()
    |> Enum.join("\n")
  rescue
    _ -> ""
  end

  # HTML attributes that carry framework fingerprints
  # data-reactroot, data-v-xxxx, ng-version, wp-content classes, etc.
  defp extract_html_attributes(body) do
    parts = []

    # data-* attributes (data-reactroot, data-v-xxxx, data-ng, data-svelte, etc.)
    data_attrs =
      ~r/\bdata-[a-z][a-z0-9-]*/is
      |> Regex.scan(body)
      |> List.flatten()

    # id="root", id="app", id="__next", id="__nuxt" etc.
    id_attrs =
      ~r/\bid\s*=\s*["']([^"']+)["']/is
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(fn id -> "id=\"#{id}\"" end)

    # class attributes with framework markers (wp-content, shopify, etc.)
    class_attrs =
      ~r/\bclass\s*=\s*["']([^"']*(?:wp-|woocommerce|shopify|elementor|drupal|joomla|webflow|squarespace|wix-|gatsby|astro-|___gatsby)[^"']*)["']/is
      |> Regex.scan(body, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(fn cls -> "class=\"#{cls}\"" end)

    (parts ++ data_attrs ++ id_attrs ++ class_attrs)
    |> Enum.join("\n")
  rescue
    _ -> ""
  end

  # ============================================================================
  # JAVASCRIPT SITE DETECTION (still uses full body - that's correct here)
  # ============================================================================

  defp is_javascript_site(body_lower) do
    safe_check_js_site(body_lower)
  rescue
    _ -> false
  end

  defp safe_check_js_site(body_lower) do
    has_framework = String.contains?(body_lower, [
      "data-reactroot", "data-v-", "ng-version",
      "__next", "__nuxt", "data-svelte"
    ])

    script_count = body_lower |> String.split("<script") |> length()
    has_root_div = String.contains?(body_lower, [
      "<div id=\"root\"", "<div id=\"app\"", "<div id=\"__next\""
    ])

    html_content = body_lower
      |> String.replace(~r/<script.*?<\/script>/s, "")

    minimal_html = byte_size(html_content) < 200

    has_framework or
      (script_count >= 3 and has_root_div) or
      (script_count >= 5 and minimal_html)
  end

  # ============================================================================
  # UTF-8 SAFETY
  # ============================================================================

  defp safe_scrub(body) when is_binary(body) do
    case :unicode.characters_to_binary(body, :utf8, :utf8) do
      {:error, good, _bad} -> good
      {:incomplete, good, _bad} -> good
      clean when is_binary(clean) -> clean
    end
  rescue
    _ -> ""
  end
  defp safe_scrub(_), do: ""
end
