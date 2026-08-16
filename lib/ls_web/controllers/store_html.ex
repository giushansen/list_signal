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

  @doc "Bronze/Silver/Gold revenue tier for the free page - exact bracket is gated."
  def revenue_tier("<$1M"), do: "🥉 Bronze"
  def revenue_tier("$1M-$10M"), do: "🥈 Silver"
  def revenue_tier(b) when b in ["$10M-$100M", "$100M-$1B", "$1B+"], do: "🥇 Gold"
  def revenue_tier(_), do: nil

  def revenue_tier_hint("<$1M"), do: "Bronze = est. under $1M/yr - sign up for the exact bracket"
  def revenue_tier_hint("$1M-$10M"), do: "Silver = est. $1M-$10M/yr - sign up for the exact bracket"
  def revenue_tier_hint(_), do: "Gold = est. over $10M/yr - sign up for the exact bracket"

  @doc "SEO score with a traffic-light dot: green >=70, amber 40-69, red <40."
  def seo_badge(score) when score >= 70, do: "🟢 #{score}/100"
  def seo_badge(score) when score >= 40, do: "🟡 #{score}/100"
  def seo_badge(score), do: "🔴 #{score}/100"

  def seo_hint(score) when score >= 70, do: "Green: strong titles, meta, links & sitemap signals"
  def seo_hint(score) when score >= 40, do: "Amber: some on-page SEO signals missing"
  def seo_hint(_), do: "Red: most on-page SEO signals missing"

end
