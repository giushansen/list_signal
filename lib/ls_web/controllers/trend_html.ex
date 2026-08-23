defmodule LSWeb.TrendHTML do
  @moduledoc false
  use LSWeb, :html
  embed_templates "trend_html/*"

  def format_number(n) when is_integer(n), do: LSWeb.StoreHTML.format_number(n)
  def format_number(_), do: "0"

  def slugify(name), do: LS.Clickhouse.tech_slug(name)

  @doc "Net movement badge: green for growth, red for shrink."
  def net_badge(assigns) do
    net = assigns.adds - assigns.drops
    assigns = assign(assigns, :net, net)

    ~H"""
    <span class={["font-semibold tabular-nums", @net >= 0 && "text-emerald-400" || "text-red-400"]}>
      <%= if @net >= 0, do: "+" %><%= format_number(@net) %>
    </span>
    """
  end
end