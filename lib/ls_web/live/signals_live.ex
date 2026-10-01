defmodule LSWeb.SignalsLive do
  @moduledoc """
  The Signals tab of the dashboard: every recorded change on a tracked
  column, newest first, filterable and exportable (data model v2,
  2026-10-01).

  A row reads as a sentence: "gymshark.com: Klaviyo added", "acme.io:
  revenue from $1M-$10M to $10M-$100M", "shop.example: started hiring (12
  roles)". The filters are the ones a buyer actually combines: what moved
  (field), which way (added, removed, changed, started, stopped, down,
  back), one exact value (a technology name, a revenue band), a domain,
  the business's country and model, and a period. The export shares the
  explorer's monthly row quota and cap, so a change row costs what a
  company row costs.

  Same rate limit and same audit trail as the explorer: a search here is a
  search.
  """
  use LSWeb, :live_view
  import LSWeb.ExplorerLive.Format

  alias LS.{Accounts, RateLimiter, Signals}
  alias LS.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    socket =
      assign(socket,
        filters: Signals.default_filters(),
        page: 1,
        per_page: 50,
        plan: User.effective_plan(user),
        rows: [],
        total: 0,
        loading: true,
        query_error: nil,
        query_ms: nil,
        tech_options: []
      )

    if connected?(socket) do
      RateLimiter.init()
      send(self(), :load)
      send(self(), :load_tech_options)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      Enum.reduce(Signals.filter_keys(), Signals.default_filters(), fn key, acc ->
        case params[to_string(key)] do
          v when is_binary(v) and v != "" -> Map.put(acc, key, String.slice(v, 0, 120))
          _ -> acc
        end
      end)

    page = params |> Map.get("page", "1") |> Integer.parse() |> elem_or(1)
    {:noreply, assign(socket, filters: filters, page: max(page, 1))}
  end

  defp elem_or({n, _}, _), do: n
  defp elem_or(_, default), do: default

  @impl true
  def handle_info(:load, socket), do: {:noreply, load(socket)}

  def handle_info(:load_tech_options, socket) do
    options =
      LS.UICache.fetch(:dropdown, :tech, fn ->
        case LS.Explorer.distinct_techs("", 800) do
          {:ok, techs} -> techs
          _ -> []
        end
      end)

    {:noreply, assign(socket, tech_options: options)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters =
      Enum.reduce(Signals.filter_keys(), socket.assigns.filters, fn key, acc ->
        Map.put(acc, key, params[to_string(key)] |> to_string() |> String.slice(0, 120))
      end)

    socket = assign(socket, filters: filters, page: 1)
    {:noreply, socket |> push_patch(to: signals_path(filters, 1)) |> load()}
  end

  def handle_event("clear", _params, socket) do
    filters = Signals.default_filters()
    socket = assign(socket, filters: filters, page: 1)
    {:noreply, socket |> push_patch(to: signals_path(filters, 1)) |> load()}
  end

  def handle_event("page", %{"page" => p}, socket) do
    page = p |> Integer.parse() |> elem_or(1) |> max(1)
    socket = assign(socket, page: page)
    {:noreply, socket |> push_patch(to: signals_path(socket.assigns.filters, page)) |> load()}
  end

  defp signals_path(filters, page) do
    params = filters |> Enum.reject(fn {_k, v} -> v in ["", nil] end) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    params = if page > 1, do: Map.put(params, "page", Integer.to_string(page)), else: params
    "/dashboard/signals?" <> URI.encode_query(params)
  end

  defp load(socket) do
    user = socket.assigns.current_scope.user
    plan = User.effective_plan(user)
    filters = socket.assigns.filters

    case RateLimiter.check(user.id, plan) do
      :ok ->
        t0 = System.monotonic_time(:millisecond)
        opts = [per_page: socket.assigns.per_page, page: socket.assigns.page]

        socket
        |> assign(loading: true, query_error: nil)
        |> Phoenix.LiveView.cancel_async(:rows, :superseded)
        |> Phoenix.LiveView.start_async(:rows, fn -> {Signals.list(filters, opts), Signals.count(filters), t0} end)

      {:error, :rate_limited} ->
        socket |> assign(loading: false) |> put_flash(:error, "Too many requests. Please slow down.")
    end
  end

  @impl true
  def handle_async(:rows, {:ok, {list_result, count_result, t0}}, socket) do
    ms = System.monotonic_time(:millisecond) - t0

    case list_result do
      {:ok, rows} ->
        total =
          case count_result do
            {:ok, n} -> n
            _ -> length(rows)
          end

        {:noreply, assign(socket, rows: rows, total: total, loading: false, query_ms: ms)}

      {:error, reason} ->
        {:noreply, assign(socket, rows: [], loading: false, query_error: reason)}
    end
  end

  def handle_async(:rows, {:exit, reason}, socket) do
    case reason do
      {:shutdown, :superseded} -> {:noreply, socket}
      :superseded -> {:noreply, socket}
      _ -> {:noreply, assign(socket, loading: false, query_error: :crashed)}
    end
  end

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :total_pages, max(div(assigns.total + assigns.per_page - 1, assigns.per_page), 1))

    ~H"""
    <div class="min-h-screen bg-[#0B0F19] text-gray-200 font-['Inter',system-ui,sans-serif]">
      <header class="border-b border-white/[0.06] bg-[#0F1628]">
        <div class="max-w-[1700px] mx-auto px-5 py-3.5 flex items-center justify-between">
          <.logo_lockup href={~p"/dashboard"} text_class="text-base" class="hover:opacity-80 transition" />
          <div class="flex items-center gap-4 text-sm">
            <.link navigate={~p"/users/settings"} class="text-gray-500 hover:text-white transition inline-flex items-center gap-1.5 text-sm">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" /><span>Settings</span>
            </.link>
            <.link href={~p"/users/log-out"} method="delete" class="text-gray-500 hover:text-white transition inline-flex items-center gap-1.5 text-sm">
              <.icon name="hero-arrow-right-start-on-rectangle" class="w-4 h-4" /><span>Log out</span>
            </.link>
          </div>
        </div>
      </header>

      <div class="max-w-[1700px] mx-auto px-5">
        <LSWeb.DashboardTabs.tabs active={:signals} />

        <form id="signals_form" phx-change="filter" class="py-4 flex items-center gap-2 flex-wrap text-[12px]">
          <select name="field" class="h-9 bg-[#141C30] border border-white/[0.08] rounded-lg px-2 text-sm text-white">
            <option value="">Any field</option>
            <%= for f <- Signals.fields() do %>
              <option value={f} selected={@filters.field == f}><%= field_label(f) %></option>
            <% end %>
          </select>
          <select name="change" class="h-9 bg-[#141C30] border border-white/[0.08] rounded-lg px-2 text-sm text-white">
            <option value="">Any change</option>
            <%= for c <- Signals.changes() do %>
              <option value={c} selected={@filters.change == c}><%= c %></option>
            <% end %>
          </select>
          <input type="text" name="value" value={@filters.value} list="signal-values" phx-debounce="400" placeholder="Value, e.g. Klaviyo"
            class="h-9 w-44 bg-[#141C30] border border-white/[0.08] rounded-lg px-3 text-sm text-white placeholder-gray-500" />
          <datalist id="signal-values">
            <%= for t <- @tech_options do %><option value={t}></option><% end %>
          </datalist>
          <input type="text" name="domain_search" value={@filters.domain_search} phx-debounce="400" placeholder="Domain"
            class="h-9 w-40 bg-[#141C30] border border-white/[0.08] rounded-lg px-3 text-sm text-white placeholder-gray-500" />
          <input type="text" name="country" value={@filters.country} phx-debounce="400" placeholder="Country, e.g. US"
            class="h-9 w-32 bg-[#141C30] border border-white/[0.08] rounded-lg px-3 text-sm text-white placeholder-gray-500" />
          <input type="text" name="business_model" value={@filters.business_model} phx-debounce="400" placeholder="Business model"
            class="h-9 w-36 bg-[#141C30] border border-white/[0.08] rounded-lg px-3 text-sm text-white placeholder-gray-500" />
          <select name="period" class="h-9 bg-[#141C30] border border-white/[0.08] rounded-lg px-2 text-sm text-white">
            <%= for {label, _days} <- Enum.sort_by(Signals.periods(), &elem(&1, 1)) do %>
              <option value={label} selected={@filters.period == label}>Last <%= label %></option>
            <% end %>
          </select>
          <button type="button" phx-click="clear" class="h-9 px-3 rounded-lg text-[12px] text-gray-500 hover:text-white transition">Clear</button>

          <div class="ml-auto">
            <%= cond do %>
              <% @plan not in ["starter", "pro"] -> %>
                <span class="inline-flex items-center h-9 px-3 rounded-lg bg-emerald-600/25 text-white/50 text-[12px] font-semibold" title="CSV export needs a paid plan">CSV</span>
              <% @total > export_cap_for(@plan) -> %>
                <span class="inline-flex items-center h-9 px-3 rounded-lg bg-white/[0.04] text-gray-600 text-[12px] font-semibold" title={"#{format_number(@total)} changes match, a CSV caps at #{format_number(export_cap_for(@plan))} rows. Narrow the filter to export."}>CSV</span>
              <% true -> %>
                <a href={~p"/dashboard/signals/export?#{filter_params(@filters)}"} data-umami-event="signals_csv_export"
                  title={"Export these changes as CSV, #{format_number(Accounts.exports_remaining(@current_scope.user))} rows left this month"}
                  class="inline-flex items-center gap-1.5 h-9 px-3 rounded-lg bg-emerald-600/90 hover:bg-emerald-500 text-white transition text-[12px] font-semibold">CSV</a>
            <% end %>
          </div>
        </form>

        <div class="flex items-center justify-between text-sm pb-3">
          <span class="text-gray-400">
            <%= cond do %>
              <% @loading -> %> Loading...
              <% @query_error -> %> <span class="text-amber-400 font-medium">Search unavailable</span>
              <% true -> %> <span class="text-white font-medium"><%= format_number(@total) %></span> changes
                <%= if @query_ms do %><span class="text-gray-600 text-xs">in <%= @query_ms %>ms</span><% end %>
            <% end %>
          </span>
          <%= if @total_pages > 1 do %>
            <div class="flex items-center gap-2 text-xs">
              <button phx-click="page" phx-value-page={@page - 1} disabled={@page <= 1} class="px-2 py-1 rounded bg-white/[0.05] disabled:opacity-30">Prev</button>
              <span class="text-gray-500">page <%= @page %> of <%= format_number(@total_pages) %></span>
              <button phx-click="page" phx-value-page={@page + 1} disabled={@page >= @total_pages} class="px-2 py-1 rounded bg-white/[0.05] disabled:opacity-30">Next</button>
            </div>
          <% end %>
        </div>

        <div class="rounded-xl border border-white/[0.06] bg-[#0F1628] overflow-hidden mb-8">
          <table id="signals-table" class="w-full text-[13px]">
            <thead>
              <tr class="bg-[#0B1020] text-[11px] font-semibold uppercase tracking-wider text-gray-400">
                <th class="px-4 py-2 text-left w-[110px]">When</th>
                <th class="px-3 py-2 text-left w-[200px]">Domain</th>
                <th class="px-3 py-2 text-left w-[140px]">Field</th>
                <th class="px-3 py-2 text-left">Change</th>
                <th class="px-3 py-2 text-left w-[90px]">Country</th>
                <th class="px-3 py-2 text-left w-[120px]">Business</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-white/[0.04]">
              <%= for r <- @rows do %>
                <tr class="hover:bg-white/[0.03]">
                  <td class="px-4 py-2.5 text-gray-500 text-[12px] whitespace-nowrap"><%= String.slice(to_string(r["changed_at"]), 0, 16) %></td>
                  <td class="px-3 py-2.5 truncate">
                    <.link navigate={~p"/dashboard?d=#{r["domain"]}"} class="text-blue-400 hover:underline font-medium"><%= r["domain"] %></.link>
                    <%= if r["http_title"] not in [nil, ""] do %>
                      <div class="text-[11px] text-gray-500 truncate" title={r["http_title"]}><%= r["http_title"] %></div>
                    <% end %>
                  </td>
                  <td class="px-3 py-2.5">
                    <span class={"px-1.5 py-0.5 rounded text-[11px] font-semibold " <> case change_tone(r["change"]) do
                      :up -> "bg-emerald-500/10 text-emerald-400"
                      :down -> "bg-amber-500/10 text-amber-400"
                      _ -> "bg-white/[0.06] text-gray-300" end}><%= field_label(r["field"]) %></span>
                  </td>
                  <td class="px-3 py-2.5 text-gray-200"><%= change_sentence(r) %></td>
                  <td class="px-3 py-2.5 text-gray-400"><%= country_flag(r["estimated_country"]) %> <%= r["estimated_country"] %></td>
                  <td class="px-3 py-2.5 text-gray-400 truncate"><%= r["estimated_business_model"] %></td>
                </tr>
              <% end %>
              <%= if @rows == [] and not @loading do %>
                <tr><td colspan="6" class="px-4 py-16 text-center text-gray-600">
                  <%= if @query_error, do: "The query failed, your filters were not applied. Please retry in a moment.", else: "No changes match. Widen the period or clear a filter." %>
                </td></tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
