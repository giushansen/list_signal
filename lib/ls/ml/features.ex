defmodule LS.ML.Features do
  @moduledoc """
  The structured hint appended to the text the classifier embeds.

  ## Why (2026-09-06)

  The ML tier embeds `title h1 meta body` with MiniLM and a logistic head
  reads the embedding. Everything the pipeline knows beyond the words on
  the page (the platform, the apps installed, the mail setup, the catalog
  size) was invisible to it, although a human labeler uses exactly those
  clues: "Shopify + 500 products + Klaviyo" is a store, "Microsoft 365 +
  DMARC reject + 40 open jobs" is an organisation with an IT department.

  Rather than change the head's input shape (384 floats everywhere, in
  training scripts and at runtime), the clues are rendered as a short,
  fixed-vocabulary sentence and appended to the text before embedding.
  One function, used by the pipeline at runtime AND by the training
  embedding script, so the model never sees a hint shape it was not
  trained on. Pure; hostile input yields "" and never raises.
  """

  @max_apps 6
  @max_tech 5

  @doc "The hint sentence for a row map (string or atom keys), or \"\"."
  @spec hint(map()) :: String.t()
  def hint(row) when is_map(row) do
    parts =
      [
        list_part("platform", get(row, :http_tech), @max_tech),
        list_part("apps", get(row, :http_apps), @max_apps),
        mail_part(row),
        count_part("products", get(row, :product_count)),
        count_part("jobs", get(row, :job_count)),
        count_part("pages", get(row, :sitemap_urls)),
        if(get(row, :dns_ms_enterprise) not in [nil, ""], do: "microsoft enterprise", else: nil),
        if(get(row, :dns_bimi) not in [nil, ""], do: "bimi brand", else: nil)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    case parts do
      [] -> ""
      _ -> "hints: " <> Enum.join(parts, "; ")
    end
  rescue
    _ -> ""
  end

  def hint(_), do: ""

  @doc "Text plus hint, the exact string the classifier embeds. Pure."
  @spec text_with_hint(String.t(), map()) :: String.t()
  def text_with_hint(text, row) when is_binary(text) do
    case hint(row) do
      "" -> String.trim(text)
      h -> String.trim(text) <> " " <> h
    end
  end

  def text_with_hint(_, _), do: ""

  defp list_part(label, value, max) when is_binary(value) and value != "" do
    items =
      value
      |> String.split("|", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.slice(&1, 0, 40))
      |> Enum.take(max)

    if items == [], do: nil, else: "#{label} " <> Enum.join(items, ", ")
  end

  defp list_part(_, _, _), do: nil

  defp mail_part(row) do
    mx = get(row, :dns_mx)
    dkim = get(row, :dns_dkim)
    dmarc = get(row, :dns_dmarc)

    provider =
      cond do
        not is_binary(mx) or mx == "" -> nil
        String.contains?(String.downcase(mx), "google") -> "google workspace"
        String.contains?(String.downcase(mx), "outlook") -> "microsoft 365"
        is_binary(dkim) and dkim =~ ~r/selector[12]/ -> "microsoft 365"
        true -> "own mail"
      end

    policy = if is_binary(dmarc) and dmarc != "", do: "dmarc #{String.slice(dmarc, 0, 10)}", else: nil

    case Enum.reject([provider, policy], &is_nil/1) do
      [] -> nil
      ps -> "mail " <> Enum.join(ps, " ")
    end
  end

  defp count_part(label, n) when is_integer(n) and n > 0, do: "#{label} #{bucket(n)}"
  defp count_part(_, _), do: nil

  # Coarse buckets keep the vocabulary tiny and stable.
  defp bucket(n) when n < 10, do: "few"
  defp bucket(n) when n < 100, do: "dozens"
  defp bucket(n) when n < 1_000, do: "hundreds"
  defp bucket(n) when n < 10_000, do: "thousands"
  defp bucket(_), do: "tens of thousands"

  defp get(row, key) do
    case Map.get(row, key, Map.get(row, to_string(key))) do
      v when is_binary(v) -> v
      v when is_integer(v) -> v
      v when is_float(v) -> round(v)
      _ -> nil
    end
  end
end
