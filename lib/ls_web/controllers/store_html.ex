defmodule LSWeb.StoreHTML do
  @moduledoc false
  use LSWeb, :html
  embed_templates "store_html/*"

  def response_time_label(nil), do: ""
  def response_time_label(ms) when is_integer(ms) and ms < 300, do: "Excellent"
  def response_time_label(ms) when is_integer(ms) and ms < 800, do: "Good"
  def response_time_label(ms) when is_integer(ms) and ms < 1500, do: "Average"
  def response_time_label(_), do: "Slow"

  def date_slice(nil), do: nil
  def date_slice(s) when is_binary(s), do: String.slice(s, 0, 10)
  def date_slice(_), do: nil
  @doc "1234567 -> \"1,234,567\" - store-page teaser counts."
  def format_number(n) when is_integer(n) do
    n |> Integer.to_charlist() |> Enum.reverse() |> Enum.chunk_every(3)
    |> Enum.join(",") |> String.reverse()
  end

  def format_number(n), do: to_string(n)

end
