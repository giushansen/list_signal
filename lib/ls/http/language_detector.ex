defmodule LS.HTTP.LanguageDetector do
  @moduledoc "Detect page language via text analysis with html lang fallback."

  @min_text_length 100

  def detect(body, headers, title, meta_desc) when is_binary(body) do
    text = build_text(title, meta_desc, body)
    if String.length(text) >= @min_text_length do
      detect_from_text(text) || html_lang(body) || header_lang(headers) || ""
    else
      html_lang(body) || header_lang(headers) || ""
    end
  rescue
    _ -> html_lang(body) || ""
  end
  def detect(_, _, _, _), do: ""

  defp build_text(title, meta_desc, body) do
    visible = extract_visible_text(body)
    [title || "", meta_desc || "", String.slice(visible, 0, 500)]
    |> Enum.reject(fn s -> s == "" end)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp detect_from_text(text) do
    case Paasaa.detect(text, min_length: 20) do
      "und" -> nil
      code when is_binary(code) and byte_size(code) > 0 -> iso3_to_iso2(code)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp html_lang(body) do
    case Regex.run(~r/<html[^>]*\blang\s*=\s*["']([^"']+)["']/is, body) do
      [_, lang] -> normalize(lang)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp header_lang(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        if String.downcase(k) == "content-language", do: normalize(v), else: nil
      _ -> nil
    end)
  rescue
    _ -> nil
  end

  defp extract_visible_text(body) do
    body
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-z]+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  rescue
    _ -> ""
  end

  defp normalize(lang) do
    lang
    |> String.trim()
    |> String.downcase()
    |> String.replace("_", "-")
    |> String.split(~r/[,;\s]/, parts: 2)
    |> hd()
    |> case do
      "" -> nil
      l when byte_size(l) >= 2 -> l
      _ -> nil
    end
  end

  @iso3_to_2 %{
    "eng" => "en", "fra" => "fr", "deu" => "de", "spa" => "es", "ita" => "it",
    "por" => "pt", "nld" => "nl", "rus" => "ru", "jpn" => "ja", "zho" => "zh",
    "kor" => "ko", "ara" => "ar", "arb" => "ar", "hin" => "hi", "tur" => "tr", "pol" => "pl",
    "ukr" => "uk", "vie" => "vi", "tha" => "th", "ces" => "cs", "ell" => "el",
    "hun" => "hu", "ron" => "ro", "bul" => "bg", "hrv" => "hr", "srp" => "sr",
    "slk" => "sk", "slv" => "sl", "dan" => "da", "fin" => "fi", "nor" => "no",
    "nob" => "nb", "nno" => "nn", "swe" => "sv", "cat" => "ca", "eus" => "eu",
    "glg" => "gl", "ind" => "id", "msa" => "ms", "tgl" => "tl", "heb" => "he",
    "fas" => "fa", "urd" => "ur", "ben" => "bn", "tam" => "ta", "tel" => "te",
    "mar" => "mr", "guj" => "gu", "kan" => "kn", "mal" => "ml", "pan" => "pa",
    "mya" => "my", "khm" => "km", "lao" => "lo", "kat" => "ka", "hye" => "hy",
    "lit" => "lt", "lav" => "lv", "est" => "et", "sqi" => "sq", "mkd" => "mk",
    "bos" => "bs", "isl" => "is", "gle" => "ga", "cym" => "cy", "afr" => "af",
    "swa" => "sw", "amh" => "am", "nep" => "ne", "sin" => "si", "mon" => "mn",
    "kaz" => "kk", "uzb" => "uz", "aze" => "az", "bel" => "be", "tat" => "tt",
  }

  defp iso3_to_iso2(code) do
    Map.get(@iso3_to_2, code, code)
  end
end
