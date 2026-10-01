defmodule LSWeb.DashboardTabs do
  @moduledoc """
  The two tabs of the paid dashboard: Businesses (the explorer) and Signals
  (the change feed). One component so both LiveViews draw the same bar.
  """
  use Phoenix.Component
  use LSWeb, :verified_routes

  attr :active, :atom, required: true, values: [:businesses, :signals]

  def tabs(assigns) do
    ~H"""
    <nav class="flex items-center gap-1 pt-4 border-b border-white/[0.06]" aria-label="Dashboard sections">
      <.tab href={~p"/dashboard"} active={@active == :businesses} label="Businesses" hint="Every business ListSignal knows, filterable and exportable" />
      <.tab href={~p"/dashboard/signals"} active={@active == :signals} label="Signals" hint="What changed: technologies added or removed, hiring started, revenue bands moved" />
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :active, :boolean, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true

  defp tab(assigns) do
    ~H"""
    <.link navigate={@href} title={@hint}
      class={"px-4 py-2 text-[13px] font-semibold border-b-2 -mb-px transition " <>
        if(@active, do: "border-emerald-500 text-white", else: "border-transparent text-gray-500 hover:text-gray-200")}>
      <%= @label %>
    </.link>
    """
  end
end
