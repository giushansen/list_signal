defmodule LS.HTTP.TextExtractor do
  @moduledoc "Extracts H1, nav link text, and visible body text for classification."

  @doc "Extracts the first <h1> content, strips inner tags, max 200 chars."
  def extract_h1(nil), do: ""
  def extract_h1(body) when is_binary(body) do
    case Regex.run(~r/<h1[^>]*>(.*?)<\/h1>/is, body) do
      [_, raw] ->
        raw
        |> String.replace(~r/<[^>]+>/, " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end
  def extract_h1(_), do: ""

  @doc "Extracts link text from <nav> or <header> elements, max 300 chars."
  def extract_nav_links(nil), do: ""
  def extract_nav_links(body) when is_binary(body) do
    nav_block =
      case Regex.run(~r/<nav[^>]*>(.*?)<\/nav>/is, body) do
        [_, content] -> content
        _ ->
          case Regex.run(~r/<header[^>]*>(.*?)<\/header>/is, body) do
            [_, content] -> content
            _ -> ""
          end
      end

    if nav_block == "" do
      ""
    else
      Regex.scan(~r/<a[^>]*>([^<]{1,100})<\/a>/is, nav_block)
      |> Enum.map(fn [_, text] -> String.trim(text) end)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
      |> String.slice(0, 300)
    end
  rescue
    _ -> ""
  end
  def extract_nav_links(_), do: ""

  @doc "Strips scripts/styles/tags, collapses whitespace, returns visible text."
  def extract_visible_text(body, max_chars \\ 500)
  def extract_visible_text(nil, _max_chars), do: ""
  def extract_visible_text(body, max_chars) when is_binary(body) do
    body
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, " ")
    |> String.replace(~r/<style[^>]*>.*?<\/style>/is, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/&[a-zA-Z]+;/, " ")
    |> String.replace(~r/&#?\w+;/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, max_chars)
  rescue
    _ -> ""
  end
  def extract_visible_text(_, _max_chars), do: ""
end
