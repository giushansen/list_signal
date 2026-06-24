defmodule LS.HTTP.Entities do
  @moduledoc """
  Decodes HTML/XML character entities to readable Unicode text.

  Extracted page text (title, meta description, H1, body) is taken from raw HTML
  with regex, so it arrives entity-encoded (`&amp;`, `&#39;`, `&#x27;`, `&eacute;`,
  `&#8211;`). We decode it once at extraction time so what we store — and show — is
  readable text, not markup.

  Handles decimal (`&#8211;`) and hex (`&#x27;`) numeric references in full, plus the
  named entities that actually occur in titles/descriptions (Latin-1 accents, quotes,
  dashes, currency, symbols). Unknown named entities and bare `&` are left untouched,
  so the function is loss-free and idempotent.
  """

  # Named entities common in page titles/descriptions. Numeric refs are handled generically.
  @named %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "ensp" => " ",
    "emsp" => " ",
    "thinsp" => " ",
    "shy" => "",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "deg" => "°",
    "micro" => "µ",
    "hellip" => "…",
    "mdash" => "—",
    "ndash" => "–",
    "minus" => "−",
    "lsquo" => "‘",
    "rsquo" => "’",
    "sbquo" => "‚",
    "ldquo" => "“",
    "rdquo" => "”",
    "bdquo" => "„",
    "laquo" => "«",
    "raquo" => "»",
    "lsaquo" => "‹",
    "rsaquo" => "›",
    "prime" => "′",
    "Prime" => "″",
    "bull" => "•",
    "middot" => "·",
    "sect" => "§",
    "para" => "¶",
    "dagger" => "†",
    "Dagger" => "‡",
    "permil" => "‰",
    "euro" => "€",
    "pound" => "£",
    "cent" => "¢",
    "yen" => "¥",
    "curren" => "¤",
    "frac12" => "½",
    "frac14" => "¼",
    "frac34" => "¾",
    "times" => "×",
    "divide" => "÷",
    "plusmn" => "±",
    "ne" => "≠",
    "le" => "≤",
    "ge" => "≥",
    "ordf" => "ª",
    "ordm" => "º",
    "iexcl" => "¡",
    "iquest" => "¿",
    "szlig" => "ß",
    "agrave" => "à",
    "aacute" => "á",
    "acirc" => "â",
    "atilde" => "ã",
    "auml" => "ä",
    "aring" => "å",
    "aelig" => "æ",
    "ccedil" => "ç",
    "egrave" => "è",
    "eacute" => "é",
    "ecirc" => "ê",
    "euml" => "ë",
    "igrave" => "ì",
    "iacute" => "í",
    "icirc" => "î",
    "iuml" => "ï",
    "ntilde" => "ñ",
    "ograve" => "ò",
    "oacute" => "ó",
    "ocirc" => "ô",
    "otilde" => "õ",
    "ouml" => "ö",
    "oslash" => "ø",
    "oelig" => "œ",
    "ugrave" => "ù",
    "uacute" => "ú",
    "ucirc" => "û",
    "uuml" => "ü",
    "yacute" => "ý",
    "yuml" => "ÿ",
    "Agrave" => "À",
    "Aacute" => "Á",
    "Acirc" => "Â",
    "Atilde" => "Ã",
    "Auml" => "Ä",
    "Aring" => "Å",
    "AElig" => "Æ",
    "Ccedil" => "Ç",
    "Egrave" => "È",
    "Eacute" => "É",
    "Ecirc" => "Ê",
    "Euml" => "Ë",
    "Igrave" => "Ì",
    "Iacute" => "Í",
    "Icirc" => "Î",
    "Iuml" => "Ï",
    "Ntilde" => "Ñ",
    "Ograve" => "Ò",
    "Oacute" => "Ó",
    "Ocirc" => "Ô",
    "Otilde" => "Õ",
    "Ouml" => "Ö",
    "Oslash" => "Ø",
    "OElig" => "Œ",
    "Ugrave" => "Ù",
    "Uacute" => "Ú",
    "Ucirc" => "Û",
    "Uuml" => "Ü",
    "Yacute" => "Ý",
    # Greek (lower)
    "alpha" => "α",
    "beta" => "β",
    "gamma" => "γ",
    "delta" => "δ",
    "epsilon" => "ε",
    "zeta" => "ζ",
    "eta" => "η",
    "theta" => "θ",
    "iota" => "ι",
    "kappa" => "κ",
    "lambda" => "λ",
    "mu" => "μ",
    "nu" => "ν",
    "xi" => "ξ",
    "omicron" => "ο",
    "pi" => "π",
    "rho" => "ρ",
    "sigmaf" => "ς",
    "sigma" => "σ",
    "tau" => "τ",
    "upsilon" => "υ",
    "phi" => "φ",
    "chi" => "χ",
    "psi" => "ψ",
    "omega" => "ω",
    # Greek (upper)
    "Gamma" => "Γ",
    "Delta" => "Δ",
    "Theta" => "Θ",
    "Lambda" => "Λ",
    "Xi" => "Ξ",
    "Pi" => "Π",
    "Sigma" => "Σ",
    "Phi" => "Φ",
    "Psi" => "Ψ",
    "Omega" => "Ω",
    # Arrows, suits, math/misc symbols
    "larr" => "←",
    "rarr" => "→",
    "uarr" => "↑",
    "darr" => "↓",
    "harr" => "↔",
    "spades" => "♠",
    "clubs" => "♣",
    "hearts" => "♥",
    "diams" => "♦",
    "check" => "✓",
    "cross" => "✗",
    "star" => "★",
    "loz" => "◊",
    "scaron" => "š",
    "Scaron" => "Š",
    "acute" => "´",
    "infin" => "∞",
    "asymp" => "≈",
    "equiv" => "≡",
    "sum" => "∑",
    "prod" => "∏",
    "radic" => "√",
    "part" => "∂",
    "int" => "∫",
    "nabla" => "∇",
    "period" => ".",
    "comma" => ",",
    "vert" => "|",
    "eth" => "ð",
    "ETH" => "Ð"
  }

  # Hex ref | decimal ref | named ref — each with its trailing ';'.
  @re ~r/&#[xX]([0-9a-fA-F]+);|&#(\d+);|&([a-zA-Z][a-zA-Z0-9]*);/

  @doc "Decode HTML entities in `text`. Loss-free, idempotent; nil/non-binary → \"\"."
  def decode(nil), do: ""
  def decode(text) when is_binary(text), do: do_decode(text, 5)
  def decode(_), do: ""

  # Decode to a fixpoint so multiply-encoded source (`&amp;amp;` → `&amp;` → `&`)
  # fully resolves. Bounded to a few passes; stops as soon as a pass is a no-op.
  defp do_decode(text, 0), do: text

  defp do_decode(text, passes) do
    # Fast path: no '&' means nothing to decode (the overwhelmingly common case).
    if :binary.match(text, "&") == :nomatch do
      text
    else
      decoded =
        Regex.replace(@re, text, fn
          whole, hex, _dec, _name when hex not in ["", nil] ->
            from_codepoint(String.to_integer(hex, 16), whole)

          whole, _hex, dec, _name when dec not in ["", nil] ->
            from_codepoint(String.to_integer(dec), whole)

          whole, _hex, _dec, name ->
            Map.get(@named, name, whole)
        end)

      if decoded == text, do: text, else: do_decode(decoded, passes - 1)
    end
  end

  # Build a UTF-8 char from a codepoint, leaving the original entity intact for
  # invalid/surrogate/out-of-range/control values.
  defp from_codepoint(cp, original)
       when cp in 0x20..0xD7FF or cp in 0xE000..0x10FFFF or cp in [0x09, 0x0A, 0x0D] do
    <<cp::utf8>>
  rescue
    _ -> original
  end

  defp from_codepoint(_, original), do: original
end
