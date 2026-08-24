defmodule LS.Countries do
  @moduledoc """
  ISO country codes to display names.

  Lives here rather than in the LiveView because emails quote a customer's
  saved search back to them: if the dashboard says "France" and the email says
  "FR", the customer has to work out that they are the same search.
  """

  @names %{
    "AD" => "Andorra", "AE" => "United Arab Emirates", "AF" => "Afghanistan", "AG" => "Antigua & Barbuda",
    "AL" => "Albania", "AM" => "Armenia", "AO" => "Angola", "AR" => "Argentina", "AT" => "Austria",
    "AU" => "Australia", "AZ" => "Azerbaijan", "BA" => "Bosnia", "BB" => "Barbados", "BD" => "Bangladesh",
    "BE" => "Belgium", "BG" => "Bulgaria", "BH" => "Bahrain", "BM" => "Bermuda", "BN" => "Brunei",
    "BO" => "Bolivia", "BR" => "Brazil", "BS" => "Bahamas", "BW" => "Botswana", "BY" => "Belarus",
    "BZ" => "Belize", "CA" => "Canada", "CD" => "DR Congo", "CH" => "Switzerland", "CI" => "Ivory Coast",
    "CL" => "Chile", "CM" => "Cameroon", "CN" => "China", "CO" => "Colombia", "CR" => "Costa Rica",
    "CU" => "Cuba", "CW" => "Curacao", "CY" => "Cyprus", "CZ" => "Czechia", "DE" => "Germany",
    "DK" => "Denmark", "DO" => "Dominican Republic", "DZ" => "Algeria", "EC" => "Ecuador", "EE" => "Estonia",
    "EG" => "Egypt", "ES" => "Spain", "ET" => "Ethiopia", "FI" => "Finland", "FJ" => "Fiji",
    "FR" => "France", "GA" => "Gabon", "GB" => "United Kingdom", "GE" => "Georgia", "GH" => "Ghana",
    "GR" => "Greece", "GT" => "Guatemala", "GU" => "Guam", "HK" => "Hong Kong", "HN" => "Honduras",
    "HR" => "Croatia", "HU" => "Hungary", "ID" => "Indonesia", "IE" => "Ireland", "IL" => "Israel",
    "IN" => "India", "IQ" => "Iraq", "IR" => "Iran", "IS" => "Iceland", "IT" => "Italy",
    "JM" => "Jamaica", "JO" => "Jordan", "JP" => "Japan", "KE" => "Kenya", "KG" => "Kyrgyzstan",
    "KH" => "Cambodia", "KR" => "South Korea", "KW" => "Kuwait", "KY" => "Cayman Islands", "KZ" => "Kazakhstan",
    "LA" => "Laos", "LB" => "Lebanon", "LI" => "Liechtenstein", "LK" => "Sri Lanka", "LT" => "Lithuania",
    "LU" => "Luxembourg", "LV" => "Latvia", "LY" => "Libya", "MA" => "Morocco", "MC" => "Monaco",
    "MD" => "Moldova", "ME" => "Montenegro", "MG" => "Madagascar", "MK" => "North Macedonia", "MM" => "Myanmar",
    "MN" => "Mongolia", "MO" => "Macau", "MT" => "Malta", "MU" => "Mauritius", "MV" => "Maldives",
    "MX" => "Mexico", "MY" => "Malaysia", "MZ" => "Mozambique", "NA" => "Namibia", "NG" => "Nigeria",
    "NI" => "Nicaragua", "NL" => "Netherlands", "NO" => "Norway", "NP" => "Nepal", "NZ" => "New Zealand",
    "OM" => "Oman", "PA" => "Panama", "PE" => "Peru", "PH" => "Philippines", "PK" => "Pakistan",
    "PL" => "Poland", "PR" => "Puerto Rico", "PS" => "Palestine", "PT" => "Portugal", "PY" => "Paraguay",
    "QA" => "Qatar", "RO" => "Romania", "RS" => "Serbia", "RU" => "Russia", "RW" => "Rwanda",
    "SA" => "Saudi Arabia", "SC" => "Seychelles", "SD" => "Sudan", "SE" => "Sweden", "SG" => "Singapore",
    "SI" => "Slovenia", "SK" => "Slovakia", "SN" => "Senegal", "SO" => "Somalia", "SV" => "El Salvador",
    "TH" => "Thailand", "TN" => "Tunisia", "TR" => "Turkey", "TT" => "Trinidad & Tobago", "TW" => "Taiwan",
    "TZ" => "Tanzania", "UA" => "Ukraine", "UG" => "Uganda", "US" => "United States", "UY" => "Uruguay",
    "UZ" => "Uzbekistan", "VE" => "Venezuela", "VG" => "British Virgin Islands", "VI" => "US Virgin Islands",
    "VN" => "Vietnam", "ZA" => "South Africa", "ZM" => "Zambia", "ZW" => "Zimbabwe"
  }

  @doc "Display name for a code, falling back to the code itself."
  def name(code) when is_binary(code), do: Map.get(@names, String.upcase(code), code)
  def name(_), do: ""

  @doc "Every known code."
  def codes, do: Map.keys(@names)
end
