defmodule LSWeb.PageHTML do
  @moduledoc false
  use LSWeb, :html
  embed_templates "page_html/*"

  @doc "ClickHouse type as a customer reads it on the data dictionary."
  def friendly_type("Array(" <> _), do: "list"
  def friendly_type("Nullable(DateTime)"), do: "date"
  def friendly_type("DateTime"), do: "date"
  def friendly_type("Nullable(Float32)"), do: "number"
  def friendly_type("Nullable(" <> _), do: "number"
  def friendly_type("UInt8"), do: "flag"
  def friendly_type(_), do: "text"

  @doc "The signal column of the data dictionary."
  def signal_label(nil), do: ""
  def signal_label(:set), do: "added, removed"
  def signal_label(:set_added), do: "added"
  def signal_label(:changed), do: "changed"
  def signal_label(:started_stopped), do: "started, stopped"
  def signal_label(:down_back), do: "down, back"
  def signal_label({:pct, p}), do: "changed by #{round(p * 100)}% or more"
end
