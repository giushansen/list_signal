defmodule LSWeb.ExplorerLive.Format do
  @moduledoc """
  Pure helpers behind the explorer's cells, badges and dropdown labels:
  number, rank and date formatting, the depth cells that show "-" for a
  business nobody has looked at yet, evidence and DNS parsing, country and
  language names. Imported by `LSWeb.ExplorerLive`; none of them touch the
  socket. Split out on 2026-09-09 so the LiveView reads as a LiveView.
  """

  def country_flag(code) when is_binary(code) and byte_size(code) == 2 do
    code |> String.upcase() |> String.to_charlist() |> Enum.map(fn c -> c - ?A + 0x1F1E6 end) |> List.to_string()
  end
  def country_flag(_), do: ""

  def format_tech(tech) when is_binary(tech), do: tech |> String.split("|") |> Enum.reject(&(&1 == ""))
  def format_tech(_), do: []

  def format_subdomains(subs) when is_binary(subs) and subs != "", do: subs |> String.split("|") |> Enum.reject(&(&1 == ""))
  def format_subdomains(_), do: []

  def format_evidence(ev) when is_binary(ev) and ev != "", do: ev |> String.split("|") |> Enum.reject(&(&1 == ""))
  def format_evidence(_), do: []

  def format_pipe_list(v) when is_binary(v) and v != "", do: v |> String.split("|") |> Enum.reject(&(&1 == ""))
  def format_pipe_list(_), do: []

  def format_response_time(nil), do: "-"
  def format_response_time(ms) when is_integer(ms), do: "#{ms}ms"
  def format_response_time(ms) when is_binary(ms), do: "#{ms}ms"
  def format_response_time(_), do: "-"

  def freshness_label(enriched_at) when is_binary(enriched_at) do
    case DateTime.from_iso8601(enriched_at <> "Z") do
      {:ok, dt, _} ->
        hours = div(DateTime.diff(DateTime.utc_now(), dt, :second), 3600)
        cond do
          hours < 24 -> "< 24h"
          hours < 168 -> "< 7d"
          hours < 720 -> "< 30d"
          true -> "> 30d"
        end
      _ -> ""
    end
  end
  def freshness_label(_), do: ""

  def has_value?(nil), do: false
  def has_value?(""), do: false
  def has_value?(0), do: false
  def has_value?("0"), do: false
  def has_value?(_), do: true

  def any_flag?(detail) do
    Enum.any?(["is_malware", "is_phishing", "is_disposable_email"], fn k ->
      detail[k] in [true, 1, "1", "true"]
    end)
  end

  # Mirrors LSWeb.ExportController.export_cap/1 — the UI must promise exactly
  # what the controller will deliver, or the file silently disappoints.
  def export_cap_for("pro"), do: 25_000
  def export_cap_for("starter"), do: 2_500
  def export_cap_for(_), do: 0

  # Depth cells: an un-enriched business shows an em dash, never a zero.
  # "0 products" reads as "sells nothing"; "-" reads as "not looked at yet",
  # which is the truth and the difference a buyer cares about.
  # "✓" cells: hover shows which authoritative source verified the value.
  def verified_title(row, field) do
    case row["verified_#{field}_source"] do
      s when s in [nil, ""] -> "estimated"
      s -> "verified via #{s}"
    end
  end

  def depth_num(nil), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))
  def depth_num(""), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))

  def depth_num(v) do
    case to_int(v) do
      0 -> Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))
      n -> format_number(n)
    end
  end

  def depth_money(nil), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))
  def depth_money(""), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))

  def depth_money(v) do
    case to_float(v) do
      f when f > 0 -> "$" <> :erlang.float_to_binary(f, decimals: 0)
      _ -> Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))
    end
  end

  def seo_cell(nil), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))
  def seo_cell(""), do: Phoenix.HTML.raw(~s(<span class="text-gray-600">-</span>))

  def seo_cell(v) do
    score = to_int(v)

    colour =
      cond do
        score >= 80 -> "text-emerald-400"
        score >= 50 -> "text-amber-400"
        true -> "text-red-400"
      end

    Phoenix.HTML.raw(~s(<span class="#{colour}">#{score}</span>))
  end

  def to_int(nil), do: 0
  def to_int(n) when is_integer(n), do: n
  def to_int(n) when is_float(n), do: trunc(n)

  def to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  def to_int(_), do: 0

  def to_float(n) when is_float(n), do: n
  def to_float(n) when is_integer(n), do: n * 1.0

  def to_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  def to_float(_), do: 0.0

  def format_number(n) when is_integer(n) do
    n |> Integer.to_string() |> String.graphemes() |> Enum.reverse() |> Enum.chunk_every(3) |> Enum.join(",") |> String.reverse()
  end
  def format_number(n), do: to_string(n)

  def format_rank(nil), do: nil
  def format_rank(0), do: nil
  def format_rank(""), do: nil
  def format_rank("0"), do: nil
  def format_rank(n) when is_integer(n), do: "##{format_number(n)}"
  def format_rank(n) when is_binary(n), do: "##{n}"
  def format_rank(_), do: nil

  def format_date(nil), do: nil
  def format_date(""), do: nil
  def format_date(dt) when is_binary(dt) do
    case Date.from_iso8601(String.slice(dt, 0, 10)) do
      {:ok, d} -> Calendar.strftime(d, "%b %d, %Y")
      _ -> dt
    end
  end
  def format_date(_), do: nil

  def format_pct(nil), do: nil
  def format_pct(""), do: nil
  def format_pct(v) when is_float(v), do: "#{round(v * 100)}%"
  def format_pct(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> "#{round(f * 100)}%"
      :error -> v
    end
  end
  def format_pct(v) when is_integer(v), do: "#{v}%"
  def format_pct(_), do: nil

  def filter_params(filters) do
    filters |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end) |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # Badge system: :gold, :silver, :bronze
  def badge_class(:gold), do: "px-2 py-0.5 rounded-full text-[9px] font-bold uppercase bg-amber-400/15 text-amber-400 ring-1 ring-amber-400/30"
  def badge_class(:silver), do: "px-2 py-0.5 rounded-full text-[9px] font-bold uppercase bg-gray-300/10 text-gray-300 ring-1 ring-gray-300/20"
  def badge_class(:bronze), do: "px-2 py-0.5 rounded-full text-[9px] font-bold uppercase bg-orange-500/10 text-orange-400 ring-1 ring-orange-400/25"
  def badge_class(_), do: ""

  def badge_label(:gold), do: "Gold"
  def badge_label(:silver), do: "Silver"
  def badge_label(:bronze), do: "Bronze"
  def badge_label(_), do: ""

  # MX provider detection
  def mx_provider(nil), do: nil
  def mx_provider(""), do: nil
  def mx_provider(mx) when is_binary(mx) do
    lower = String.downcase(mx)
    cond do
      String.contains?(lower, "google") or String.contains?(lower, "aspmx") -> "Google Workspace"
      String.contains?(lower, "outlook") or String.contains?(lower, "microsoft") -> "Microsoft 365"
      String.contains?(lower, "protonmail") or String.contains?(lower, "proton") -> "Proton Mail"
      String.contains?(lower, "zoho") -> "Zoho Mail"
      String.contains?(lower, "mimecast") -> "Mimecast"
      String.contains?(lower, "barracuda") -> "Barracuda"
      String.contains?(lower, "pphosted") or String.contains?(lower, "proofpoint") -> "Proofpoint"
      String.contains?(lower, "yahoodns") or String.contains?(lower, "yahoo") -> "Yahoo Mail"
      String.contains?(lower, "secureserver") or String.contains?(lower, "godaddy") -> "GoDaddy Email"
      String.contains?(lower, "ovh") -> "OVH Mail"
      true -> nil
    end
  end
  def mx_provider(_), do: nil

  def format_mx_short(nil), do: nil
  def format_mx_short(""), do: nil
  def format_mx_short(mx) when is_binary(mx) do
    mx |> String.split("|") |> hd() |> String.trim()
  end
  def format_mx_short(_), do: nil

  # Friendly content type: "text/html; charset=utf-8" -> "HTML"
  def friendly_content_type(nil), do: nil
  def friendly_content_type(""), do: nil
  def friendly_content_type(ct) when is_binary(ct) do
    lower = String.downcase(ct)
    cond do
      String.contains?(lower, "text/html") -> "HTML"
      String.contains?(lower, "application/xhtml") -> "XHTML"
      String.contains?(lower, "application/json") -> "JSON"
      String.contains?(lower, "application/xml") or String.contains?(lower, "text/xml") -> "XML"
      String.contains?(lower, "application/pdf") -> "PDF"
      String.contains?(lower, "text/plain") -> "Text"
      String.contains?(lower, "text/css") -> "CSS"
      String.contains?(lower, "javascript") -> "JavaScript"
      String.contains?(lower, "image/") -> "Image"
      String.contains?(lower, "video/") -> "Video"
      String.contains?(lower, "audio/") -> "Audio"
      true -> ct |> String.split(";") |> hd() |> String.trim()
    end
  end
  def friendly_content_type(_), do: nil

  # DKIM/DMARC parser
  def parse_dkim(nil), do: nil
  def parse_dkim(""), do: nil
  def parse_dkim(txt) when is_binary(txt) do
    records = String.split(txt, "|")
    dmarc = Enum.find(records, fn r -> String.contains?(r, "v=DMARC1") end)
    has_dkim = Enum.any?(records, fn r -> String.contains?(r, "v=DKIM1") or String.contains?(r, "k=rsa") end)

    cond do
      dmarc && String.contains?(dmarc, "p=reject") ->
        %{tier: :gold, emoji: "🏆", summary: "DMARC reject policy" <> if(has_dkim, do: " + DKIM", else: "")}

      dmarc && String.contains?(dmarc, "p=quarantine") ->
        %{tier: :gold, emoji: "⭐", summary: "DMARC quarantine" <> if(has_dkim, do: " + DKIM", else: "")}

      dmarc && String.contains?(dmarc, "p=none") ->
        %{tier: :silver, emoji: "✓", summary: "DMARC monitoring only" <> if(has_dkim, do: " + DKIM", else: "")}

      has_dkim ->
        %{tier: :silver, emoji: "✓", summary: "DKIM configured"}

      true -> nil
    end
  end
  def parse_dkim(_), do: nil

  # Evidence parsing: "tranco:top_100k:25741->mid_market" -> {:gold, "Tranco #25,741, Mid Market"}
  def parse_evidence_item(item) when is_binary(item) do
    case String.split(item, [":", "→", "->"], parts: 4) do
      [signal, tier, val, estimate] ->
        badge = evidence_signal_tier(signal, tier)
        label = "#{humanize_signal(signal)} #{humanize_val(val)}, #{humanize_estimate(estimate)}"
        {badge, label}
      [signal, tier, val_or_est] ->
        badge = evidence_signal_tier(signal, tier)
        {badge, "#{humanize_signal(signal)} #{humanize_val(tier)}, #{humanize_estimate(val_or_est)}"}
      _ -> {:bronze, item}
    end
  end
  def parse_evidence_item(item), do: {:bronze, to_string(item)}

  def evidence_signal_tier(signal, tier) do
    t = String.downcase(tier)
    cond do
      String.contains?(t, "enterprise") or String.contains?(t, "top_10k") or String.contains?(t, "top_50k") -> :gold
      String.contains?(t, "mid_market") or String.contains?(t, "top_100k") or String.contains?(t, "top_500k") -> :gold
      String.contains?(t, "small") or String.contains?(t, "top_1m") -> :silver
      String.contains?(t, "micro") or String.contains?(t, "basic") -> :bronze
      String.downcase(signal) in ~w(tranco majestic ref_subnets) -> :silver
      true -> :bronze
    end
  end

  def humanize_signal(s) do
    case String.downcase(s) do
      "tranco" -> "Tranco"
      "majestic" -> "Majestic"
      "ref_subnets" -> "Ref Subnets"
      "ssl_issuer" -> "SSL"
      "mx" -> "Email"
      "spf_includes" -> "SPF"
      "tech_count" -> "Tech Stack"
      "app_count" -> "Apps"
      "cms" -> "CMS"
      "tools" -> "Tool"
      other -> other |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def humanize_val(v) do
    case Integer.parse(v) do
      {n, _} when n > 999 -> "##{format_number(n)}"
      {n, _} -> "#{n}"
      :error -> v |> String.replace("_", " ")
    end
  end

  def humanize_estimate(e), do: e |> String.replace("_", " ") |> String.capitalize()

  def evidence_tier_class(:gold), do: "w-2 h-2 rounded-full bg-amber-400 flex-shrink-0"
  def evidence_tier_class(:silver), do: "w-2 h-2 rounded-full bg-gray-300 flex-shrink-0"
  def evidence_tier_class(:bronze), do: "w-2 h-2 rounded-full bg-orange-500 flex-shrink-0"
  def evidence_tier_class(_), do: "w-2 h-2 rounded-full bg-gray-600 flex-shrink-0"

  def evidence_tier_dot(:gold), do: ""
  def evidence_tier_dot(:silver), do: ""
  def evidence_tier_dot(:bronze), do: ""
  def evidence_tier_dot(_), do: ""

  def evidence_tier_text_class(:gold), do: "text-amber-400 font-medium"
  def evidence_tier_text_class(:silver), do: "text-gray-300"
  def evidence_tier_text_class(:bronze), do: "text-orange-400/80"
  def evidence_tier_text_class(_), do: "text-gray-500"

  # Section badges
  def tech_section_badge(d) do
    count = length(format_tech(d["http_tech"]))
    cond do
      count >= 8 -> :gold
      count >= 4 -> :silver
      count >= 1 -> :bronze
      true -> nil
    end
  end

  def app_section_badge(d) do
    count = length(format_pipe_list(d["http_apps"]))
    cond do
      count >= 5 -> :gold
      count >= 2 -> :silver
      count >= 1 -> :bronze
      true -> nil
    end
  end

  def dns_section_badge(d) do
    mx = mx_provider(d["dns_mx"])
    cond do
      mx in ["Google Workspace", "Microsoft 365", "Proofpoint", "Mimecast"] -> :gold
      mx != nil -> :silver
      has_value?(d["dns_mx"]) -> :bronze
      true -> nil
    end
  end

  def network_section_badge(d) do
    org = to_string(d["bgp_asn_org"]) |> String.downcase()
    cond do
      String.contains?(org, "amazon") or String.contains?(org, "aws") -> :gold
      String.contains?(org, "google") or String.contains?(org, "gcp") -> :gold
      String.contains?(org, "cloudflare") -> :gold
      String.contains?(org, "microsoft") or String.contains?(org, "azure") -> :gold
      String.contains?(org, "fastly") or String.contains?(org, "akamai") -> :silver
      String.contains?(org, "digitalocean") or String.contains?(org, "hetzner") -> :silver
      String.contains?(org, "ovh") or String.contains?(org, "linode") -> :silver
      has_value?(d["bgp_asn_org"]) -> :bronze
      true -> nil
    end
  end

  def domain_section_badge(d) do
    registrar = to_string(d["rdap_registrar"]) |> String.downcase()
    has_dates = has_value?(d["rdap_domain_created_at"])
    cond do
      String.contains?(registrar, "markmonitor") or String.contains?(registrar, "csc") -> :gold
      String.contains?(registrar, "networksolutions") or String.contains?(registrar, "safenames") -> :gold
      has_dates and has_value?(d["rdap_registrar"]) -> :silver
      has_dates -> :bronze
      true -> nil
    end
  end

  def ssl_section_badge(d) do
    sub_count = parse_int(d["ctl_subdomain_count"])
    issuer = to_string(d["ctl_issuer"]) |> String.downcase()
    cond do
      sub_count >= 20 or String.contains?(issuer, "digicert") or String.contains?(issuer, "globalsign") -> :gold
      sub_count >= 5 or String.contains?(issuer, "amazon") or String.contains?(issuer, "sectigo") -> :silver
      has_value?(d["ctl_issuer"]) -> :bronze
      true -> nil
    end
  end

  def rankings_section_badge(d) do
    tranco = parse_int(d["tranco_rank"])
    majestic = parse_int(d["majestic_rank"])
    best = Enum.min([tranco || 999_999_999, majestic || 999_999_999])
    cond do
      best <= 100_000 -> :gold
      best <= 500_000 -> :silver
      best <= 2_000_000 -> :bronze
      true -> nil
    end
  end

  def parse_int(nil), do: nil
  def parse_int(n) when is_integer(n), do: n
  def parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
  def parse_int(_), do: nil


  def country_name(code), do: LS.Countries.name(code)

  @language_names %{
    "en" => "English", "fr" => "French", "de" => "German", "es" => "Spanish", "it" => "Italian",
    "pt" => "Portuguese", "nl" => "Dutch", "ru" => "Russian", "zh" => "Chinese", "ja" => "Japanese",
    "ko" => "Korean", "ar" => "Arabic", "hi" => "Hindi", "bn" => "Bengali", "pa" => "Punjabi",
    "tr" => "Turkish", "vi" => "Vietnamese", "th" => "Thai", "pl" => "Polish", "uk" => "Ukrainian",
    "ro" => "Romanian", "el" => "Greek", "cs" => "Czech", "sv" => "Swedish", "hu" => "Hungarian",
    "fi" => "Finnish", "da" => "Danish", "no" => "Norwegian", "sk" => "Slovak", "bg" => "Bulgarian",
    "hr" => "Croatian", "sr" => "Serbian", "sl" => "Slovenian", "lt" => "Lithuanian", "lv" => "Latvian",
    "et" => "Estonian", "ms" => "Malay", "id" => "Indonesian", "tl" => "Filipino", "he" => "Hebrew",
    "fa" => "Persian", "ur" => "Urdu", "sw" => "Swahili", "af" => "Afrikaans", "ca" => "Catalan",
    "gl" => "Galician", "eu" => "Basque", "is" => "Icelandic", "ga" => "Irish", "cy" => "Welsh",
    "sq" => "Albanian", "mk" => "Macedonian", "bs" => "Bosnian", "mt" => "Maltese", "ka" => "Georgian",
    "hy" => "Armenian", "az" => "Azerbaijani", "kk" => "Kazakh", "uz" => "Uzbek", "mn" => "Mongolian",
    "km" => "Khmer", "lo" => "Lao", "my" => "Burmese", "ne" => "Nepali", "si" => "Sinhala",
    "am" => "Amharic", "ta" => "Tamil", "te" => "Telugu", "kn" => "Kannada", "ml" => "Malayalam",
    "mr" => "Marathi", "gu" => "Gujarati"
  }

  def language_name(code) when is_binary(code), do: Map.get(@language_names, String.downcase(code), code)
  def language_name(_), do: ""

  # Whitelists: only real, curated countries/languages reach the dropdowns — this is what
  # keeps junk like "%paraglide.lang%" out of the language filter.
  def valid_country?(code), do: is_binary(code) and LS.Countries.name(code) != String.upcase(code)
  def valid_language?(code), do: is_binary(code) and Map.has_key?(@language_names, String.downcase(code))

  # Text a dropdown option is matched against when the user types (client-side filtering).
  def option_search_text("country", code), do: String.downcase("#{country_name(code)} #{code}")
  def option_search_text("language", code), do: String.downcase("#{language_name(code)} #{code}")
  def option_search_text(_field, value), do: String.downcase(to_string(value))
end
