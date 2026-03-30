defmodule LSWeb.TechHTML do
  use LSWeb, :html
  embed_templates "tech_html/*"

  def tech_slug(tech) do
    tech |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  def store_slug(domain) do
    String.replace(domain, ".", "-")
  end

  def bar_width(count, max) do
    c = to_num(count)
    m = to_num(max)
    if m > 0, do: "#{max(round(c / m * 100), 2)}%", else: "0%"
  end

  defp to_num(n) when is_number(n), do: n
  defp to_num(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> i
      :error -> 0
    end
  end
  defp to_num(_), do: 0
end
