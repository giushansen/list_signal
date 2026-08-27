defmodule LSWeb.HiringHTML do
  @moduledoc "Templates for the public hiring-signals page."
  use LSWeb, :html

  embed_templates "hiring_html/*"

  @doc "1234567 -> \"1,234,567\", plain numbers read as fake on a marketing page."
  def fmt(n) when is_integer(n),
    do: n |> Integer.to_string() |> String.replace(~r/(?<=\d)(?=(\d{3})+$)/, ",")

  def fmt(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> fmt(v)
      :error -> n
    end
  end

  def fmt(_), do: "0"
end
