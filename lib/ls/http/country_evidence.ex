defmodule LS.HTTP.CountryEvidence do
  @moduledoc """
  Reads a country out of the page itself, from things a business states about
  itself rather than from where its bytes happen to be served.

  ## Why this exists

  `LS.CountryInferrer` had only four signals: ccTLD, language, RDAP and BGP.
  Two of them are weak and one was ranked far too high, which produced
  customer-visible errors on 2026-08-27:

    * `intellatriage.com`, a Nashville nurse-triage service, was labelled
      French. Its only French signal was a language detection of `fr` on an
      English page, and language outranked both RDAP and BGP.
    * `eapc-us.com`, `geteino.com` and `tryeino.com` were labelled French
      because they sit on OVH. OVH and Gandi host the world.
    * `knowunity.fr` was labelled French. It is a Berlin company: its own
      site carries German VAT `DE326705352` and a `+49` number, and serves a
      French-language site to French students.

  Language says who a site is written FOR. Hosting says where the bytes are.
  Neither says who the company is. The evidence below does.

  ## Evidence, strongest first

    1. `:registration` — a VAT or company-registration number. These carry a
       country prefix by construction, are printed because the law requires
       it, and cannot be borrowed from a CDN. This is what settled knowunity.
    2. `:schema` — schema.org `addressCountry`. The site declaring its own
       postal country in structured data.
    3. `:phone` — an international dialling prefix. Strong, occasionally a
       support line in another country.
    4. `:postal` — a country-specific postcode-and-city shape.

  Anything weaker is left to `CountryInferrer`, which owns ccTLD, RDAP, BGP
  and language.

  ## Hostile input

  Page text crosses a boundary into a TabSeparated insert, and three
  production incidents came from one unescaped value destroying a batch
  (CLAUDE.md). Output here is always either `""` or exactly two uppercase
  letters, so there is nothing to escape.
  """

  @max_scan 200_000

  # VAT and company-registration numbers. The country lives in the identifier
  # itself, which is what makes this the strongest signal on the page.
  @registration [
    {~r/\bFR\s?[0-9A-Z]{2}\s?[0-9]{9}\b/i, "FR"},
    # Registries print these grouped: "552 100 554", "552.100.554".
    {~r/\b(?:siren|siret)\b[^0-9]{0,20}(?:[0-9][ .]?){9}/i, "FR"},
    {~r/\bDE\s?[0-9]{9}\b/, "DE"},
    {~r/\b(?:ust[\s.\-]?idnr|umsatzsteuer[\s\-]?identifikationsnummer)\b/i, "DE"},
    {~r/\bHRB\s?[0-9]{3,7}\b/, "DE"},
    {~r/\b(?:company\s+(?:number|no\.?)|companies\s+house)\b[^0-9]{0,15}[0-9]{6,8}/i, "GB"},
    {~r/\bGB\s?[0-9]{9}\b/, "GB"},
    {~r/\bBE\s?0[0-9]{9}\b/, "BE"},
    {~r/\bNL\s?[0-9]{9}B[0-9]{2}\b/i, "NL"},
    {~r/\b(?:kvk|kamer van koophandel)\b[^0-9]{0,15}[0-9]{8}/i, "NL"},
    {~r/\bIT\s?[0-9]{11}\b/, "IT"},
    {~r/\b(?:partita\s+iva|p\.?\s?iva)\b[^0-9]{0,15}[0-9]{11}/i, "IT"},
    {~r/\bES\s?[0-9A-Z][0-9]{7}[0-9A-Z]\b/, "ES"},
    {~r/\b(?:cif|nif)\b[^0-9A-Z]{0,10}[0-9A-Z][0-9]{7}[0-9A-Z]\b/i, "ES"},
    {~r/\bCHE[\s.\-]?[0-9]{3}\.?[0-9]{3}\.?[0-9]{3}\b/i, "CH"},
    {~r/\bATU\s?[0-9]{8}\b/i, "AT"},
    {~r/\bIE\s?[0-9][0-9A-Z][0-9]{5}[A-Z]{1,2}\b/i, "IE"},
    {~r/\bPL\s?[0-9]{10}\b/, "PL"},
    {~r/\b(?:nip)\b[^0-9]{0,10}[0-9]{10}/i, "PL"},
    {~r/\bSE\s?[0-9]{12}\b/, "SE"},
    {~r/\bDK\s?[0-9]{8}\b/, "DK"},
    {~r/\b(?:cvr)\b[^0-9]{0,10}[0-9]{8}/i, "DK"},
    {~r/\bPT\s?[0-9]{9}\b/, "PT"},
    {~r/\b(?:cnpj)\b[^0-9]{0,10}[0-9]{2}\.?[0-9]{3}\.?[0-9]{3}/i, "BR"},
    {~r/\b(?:kbo|bce)\b[^0-9]{0,10}0[0-9]{3}\.?[0-9]{3}\.?[0-9]{3}/i, "BE"},
    {~r/\b(?:abn|acn)\b[^0-9]{0,10}[0-9]{2}\s?[0-9]{3}\s?[0-9]{3}/i, "AU"}
  ]

  @schema_country ~r/"addressCountry"\s*:\s*(?:\{[^}]{0,80}?"name"\s*:\s*)?"\s*([A-Za-z][A-Za-z .]{1,30}?)\s*"/i

  # Dialling prefixes. Longest first so +351 is not read as +35.
  @phone_prefixes [
    {"351", "PT"}, {"352", "LU"}, {"353", "IE"}, {"354", "IS"}, {"356", "MT"},
    {"358", "FI"}, {"359", "BG"}, {"370", "LT"}, {"371", "LV"}, {"372", "EE"},
    {"380", "UA"}, {"385", "HR"}, {"386", "SI"}, {"420", "CZ"}, {"421", "SK"},
    {"27", "ZA"}, {"30", "GR"}, {"31", "NL"}, {"32", "BE"}, {"33", "FR"},
    {"34", "ES"}, {"36", "HU"}, {"39", "IT"}, {"40", "RO"}, {"41", "CH"},
    {"43", "AT"}, {"44", "GB"}, {"45", "DK"}, {"46", "SE"}, {"47", "NO"},
    {"48", "PL"}, {"49", "DE"}, {"52", "MX"}, {"55", "BR"}, {"61", "AU"},
    {"64", "NZ"}, {"65", "SG"}, {"81", "JP"}, {"82", "KR"}, {"86", "CN"},
    {"90", "TR"}, {"91", "IN"}, {"972", "IL"}, {"971", "AE"}, {"1", "US"}
  ]

  # Country names as written on a page, mapped to codes. Only used for the
  # schema.org field, where the value is a declared country rather than prose.
  @country_names %{
    "france" => "FR", "fr" => "FR", "germany" => "DE", "deutschland" => "DE",
    "de" => "DE", "united kingdom" => "GB", "great britain" => "GB",
    "england" => "GB", "gb" => "GB", "uk" => "GB", "united states" => "US",
    "united states of america" => "US", "usa" => "US", "us" => "US",
    "spain" => "ES", "espana" => "ES", "es" => "ES", "italy" => "IT",
    "italia" => "IT", "it" => "IT", "netherlands" => "NL", "nederland" => "NL",
    "nl" => "NL", "belgium" => "BE", "belgique" => "BE", "be" => "BE",
    "switzerland" => "CH", "suisse" => "CH", "schweiz" => "CH", "ch" => "CH",
    "austria" => "AT", "osterreich" => "AT", "at" => "AT", "ireland" => "IE",
    "ie" => "IE", "portugal" => "PT", "pt" => "PT", "poland" => "PL",
    "polska" => "PL", "pl" => "PL", "sweden" => "SE", "se" => "SE",
    "denmark" => "DK", "dk" => "DK", "norway" => "NO", "no" => "NO",
    "finland" => "FI", "fi" => "FI", "canada" => "CA", "ca" => "CA",
    "australia" => "AU", "au" => "AU", "brazil" => "BR", "brasil" => "BR",
    "br" => "BR", "india" => "IN", "in" => "IN", "japan" => "JP", "jp" => "JP",
    "singapore" => "SG", "sg" => "SG", "israel" => "IL", "il" => "IL",
    "mexico" => "MX", "mx" => "MX", "czechia" => "CZ", "czech republic" => "CZ",
    "luxembourg" => "LU", "lu" => "LU", "greece" => "GR", "gr" => "GR",
    "romania" => "RO", "ro" => "RO", "hungary" => "HU", "hu" => "HU"
  }

  @doc """
  Best country evidence on a page, as `{code, source}`.

  `{"", :none}` when the page says nothing. Never guesses: a page with no
  stated country returns nothing so `CountryInferrer` can fall back rather
  than inherit a fabricated answer.

      iex> LS.HTTP.CountryEvidence.detect(~s(<p>USt-IdNr: DE811569869</p>))
      {"DE", :registration}
      iex> LS.HTTP.CountryEvidence.detect("<p>nothing here</p>")
      {"", :none}
  """
  @spec detect(binary() | nil) :: {String.t(), atom()}
  def detect(html) when is_binary(html) do
    scan = if byte_size(html) > @max_scan, do: binary_part(html, 0, @max_scan), else: html

    with {"", _} <- {from_registration(scan), :registration},
         {"", _} <- {from_schema(scan), :schema},
         {"", _} <- {from_phone(scan), :phone} do
      {"", :none}
    else
      {code, source} -> {code, source}
    end
  rescue
    _ -> {"", :none}
  end

  def detect(_), do: {"", :none}

  @doc "Country from a VAT or company-registration number, or \"\"."
  @spec from_registration(binary()) :: String.t()
  def from_registration(text) when is_binary(text) do
    Enum.find_value(@registration, "", fn {re, cc} ->
      if Regex.match?(re, text), do: cc
    end)
  rescue
    _ -> ""
  end

  @doc "Country from a schema.org addressCountry value, or \"\"."
  @spec from_schema(binary()) :: String.t()
  def from_schema(text) when is_binary(text) do
    case Regex.run(@schema_country, text, capture: :all_but_first) do
      [raw] -> Map.get(@country_names, raw |> String.downcase() |> String.trim(), "")
      _ -> ""
    end
  rescue
    _ -> ""
  end

  @doc "Country from an international dialling prefix, or \"\"."
  @spec from_phone(binary()) :: String.t()
  def from_phone(text) when is_binary(text) do
    # Only tel: hrefs and schema telephone fields. A bare "+1" in prose is
    # noise, and a page full of prices produces plenty of it.
    candidates =
      Regex.scan(~r/(?:href=["']tel:|"telephone"\s*:\s*")\s*(\+[0-9][0-9 .\-()]{5,20})/i,
                 text, capture: :all_but_first)
      |> List.flatten()

    Enum.find_value(candidates, "", fn raw ->
      digits = String.replace(raw, ~r/[^\d]/, "")
      Enum.find_value(@phone_prefixes, nil, fn {p, cc} ->
        if String.starts_with?(digits, p), do: cc
      end)
    end) || ""
  rescue
    _ -> ""
  end

  @doc "Evidence sources in strength order, for docs and tests."
  @spec sources() :: [atom()]
  def sources, do: [:registration, :schema, :phone, :none]
end
