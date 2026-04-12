defmodule LSWeb.ExplorerLive do
  use LSWeb, :live_view

  alias LS.{Accounts, Explorer, RateLimiter}
  alias LS.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    per_page = Accounts.results_per_page(user)
    plan = User.effective_plan(user)

    filters = default_filters()

    socket =
      socket
      |> assign(
        filters: filters,
        page: 1,
        per_page: per_page,
        plan: plan,
        results: [],
        total: 0,
        loading: true,
        expanded: nil,
        detail: nil,
        show_upgrade: false,
        query_ms: nil,
        open_dropdown: nil,
        dropdown_query: "",
        dropdown_options: [],
        rate_stats: %{used: 0, limit: 10, remaining: 10, reset_in: 60}
      )

    if connected?(socket) do
      RateLimiter.init()
      :timer.send_interval(5_000, self(), :refresh_rate_stats)
      send(self(), :load_data)
      send(self(), :refresh_rate_stats)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case params["checkout"] do
        "success" -> put_flash(socket, :info, "Subscription activated! Welcome aboard.")
        "cancelled" -> put_flash(socket, :info, "Checkout cancelled.")
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:load_data, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_info(:refresh_rate_stats, socket) do
    user = socket.assigns.current_scope.user
    plan = User.effective_plan(user)
    {:noreply, assign(socket, rate_stats: RateLimiter.stats(user.id, plan))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = %{
      tech: params["tech"] || "",
      shopify_app: params["shopify_app"] || "",
      country: params["country"] || "",
      business_model: params["business_model"] || "",
      industry: params["industry"] || "",
      revenue: params["revenue"] || "",
      employees: params["employees"] || "",
      language: params["language"] || "",
      domain_search: params["domain_search"] || "",
      freshness: params["freshness"] || ""
    }

    socket =
      socket
      |> assign(filters: filters, page: 1, loading: true, expanded: nil, detail: nil)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(page: page, loading: true, expanded: nil, detail: nil)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("expand", %{"domain" => domain}, socket) do
    if socket.assigns.expanded == domain do
      {:noreply, assign(socket, expanded: nil, detail: nil)}
    else
      user = socket.assigns.current_scope.user
      plan = User.effective_plan(user)

      case RateLimiter.check(user.id, plan) do
        :ok ->
          case Explorer.get_detail(domain) do
            {:ok, detail} -> {:noreply, assign(socket, expanded: domain, detail: detail)}
            _ -> {:noreply, socket}
          end

        {:error, :rate_limited} ->
          {:noreply, put_flash(socket, :error, "Too many requests. Please slow down.")}
      end
    end
  end

  def handle_event("show_upgrade", _params, socket) do
    {:noreply, assign(socket, show_upgrade: true)}
  end

  def handle_event("close_upgrade", _params, socket) do
    {:noreply, assign(socket, show_upgrade: false)}
  end

  # Dropdown events
  def handle_event("open_dropdown", %{"field" => field}, socket) do
    if socket.assigns.open_dropdown == field do
      {:noreply, assign(socket, open_dropdown: nil, dropdown_query: "", dropdown_options: [])}
    else
      options = fetch_dropdown_options(field, "")
      {:noreply, assign(socket, open_dropdown: field, dropdown_query: "", dropdown_options: options)}
    end
  end

  def handle_event("close_dropdown", _params, socket) do
    {:noreply, assign(socket, open_dropdown: nil, dropdown_query: "", dropdown_options: [])}
  end

  def handle_event("dropdown_search", %{"value" => query}, socket) do
    field = socket.assigns.open_dropdown
    options = if field, do: fetch_dropdown_options(field, query), else: []
    {:noreply, assign(socket, dropdown_query: query, dropdown_options: options)}
  end

  def handle_event("select_option", %{"field" => field, "value" => value}, socket) do
    field_atom = String.to_existing_atom(field)
    current = Map.get(socket.assigns.filters, field_atom, "")
    current_values = current |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()

    new_values =
      if MapSet.member?(current_values, value),
        do: MapSet.delete(current_values, value),
        else: MapSet.put(current_values, value)

    new_filter = new_values |> MapSet.to_list() |> Enum.sort() |> Enum.join(",")
    filters = Map.put(socket.assigns.filters, field_atom, new_filter)

    socket =
      socket
      |> assign(filters: filters, page: 1, loading: true, expanded: nil, detail: nil)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("clear_filter", %{"field" => field}, socket) do
    field_atom = String.to_existing_atom(field)
    filters = Map.put(socket.assigns.filters, field_atom, "")

    socket =
      socket
      |> assign(filters: filters, page: 1, loading: true, expanded: nil, detail: nil, open_dropdown: nil)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("remove_tag", %{"field" => field, "value" => value}, socket) do
    field_atom = String.to_existing_atom(field)
    current = Map.get(socket.assigns.filters, field_atom, "")

    new_filter =
      current
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == value))
      |> Enum.join(",")

    filters = Map.put(socket.assigns.filters, field_atom, new_filter)

    socket =
      socket
      |> assign(filters: filters, page: 1, loading: true, expanded: nil, detail: nil)
      |> load_data()

    {:noreply, socket}
  end

  def handle_event("clear_all_filters", _params, socket) do
    socket =
      socket
      |> assign(filters: default_filters(), page: 1, loading: true, expanded: nil, detail: nil, open_dropdown: nil)
      |> load_data()

    {:noreply, socket}
  end

  defp fetch_dropdown_options("tech", query), do: fetch_techs(query)
  defp fetch_dropdown_options("shopify_app", query), do: fetch_apps(query, shopify_only: true)
  defp fetch_dropdown_options("country", query), do: fetch_distinct("country", query)
  defp fetch_dropdown_options("language", query), do: fetch_distinct("http_language", query)
  defp fetch_dropdown_options("business_model", query), do: filter_static(Explorer.business_models(), query)
  defp fetch_dropdown_options("industry", query), do: filter_static(Explorer.industries(), query)
  defp fetch_dropdown_options("revenue", query), do: filter_static(["<$1M", "$1M-$10M", "$10M-$50M", "$50M-$100M", "$100M-$1B", "$1B+"], query)
  defp fetch_dropdown_options("employees", query), do: filter_static(["1-10", "11-50", "51-200", "201-500", "501-5000", "5001+"], query)
  defp fetch_dropdown_options("freshness", query), do: filter_static(["24h", "7d", "30d"], query)
  defp fetch_dropdown_options(_, _), do: []

  defp fetch_techs(query) do
    case Explorer.distinct_techs(query, 500) do
      {:ok, techs} -> techs
      _ -> []
    end
  end

  defp fetch_apps(query, opts) do
    case Explorer.distinct_apps(query, 500, opts) do
      {:ok, apps} -> apps
      _ -> []
    end
  end

  defp fetch_distinct(column, query) do
    case Explorer.distinct_values(column, query, 500) do
      {:ok, values} -> values
      _ -> []
    end
  end

  defp filter_static(options, ""), do: options
  defp filter_static(options, query) do
    q = String.downcase(query)
    Enum.filter(options, fn opt -> String.downcase(opt) |> String.contains?(q) end)
  end

  defp load_data(socket) do
    user = socket.assigns.current_scope.user
    plan = User.effective_plan(user)
    filters = socket.assigns.filters
    filter_kw = Enum.to_list(filters)

    case RateLimiter.check(user.id, plan) do
      :ok ->
        t0 = System.monotonic_time(:millisecond)

        {results, total} =
          case {Explorer.list(filter_kw, per_page: socket.assigns.per_page, page: socket.assigns.page),
                Explorer.count(filter_kw)} do
            {{:ok, rows}, {:ok, count}} -> {rows, count}
            _ -> {[], 0}
          end

        query_ms = System.monotonic_time(:millisecond) - t0
        socket
        |> assign(results: results, total: total, loading: false, query_ms: query_ms)
        |> assign(rate_stats: RateLimiter.stats(user.id, plan))

      {:error, :rate_limited} ->
        socket
        |> assign(loading: false)
        |> put_flash(:error, "Too many requests. Please slow down.")
    end
  end

  defp default_filters do
    %{tech: "", shopify_app: "", country: "", business_model: "", industry: "", revenue: "", employees: "", language: "", domain_search: "", freshness: ""}
  end

  defp total_pages(total, per_page) when is_integer(total) and per_page > 0, do: div(total + per_page - 1, per_page)
  defp total_pages(_, _), do: 1

  defp country_flag(code) when is_binary(code) and byte_size(code) == 2 do
    code |> String.upcase() |> String.to_charlist() |> Enum.map(fn c -> c - ?A + 0x1F1E6 end) |> List.to_string()
  end
  defp country_flag(_), do: ""

  defp format_tech(tech) when is_binary(tech), do: tech |> String.split("|") |> Enum.reject(&(&1 == ""))
  defp format_tech(_), do: []

  defp format_subdomains(subs) when is_binary(subs) and subs != "", do: subs |> String.split("|") |> Enum.reject(&(&1 == ""))
  defp format_subdomains(_), do: []

  defp format_evidence(ev) when is_binary(ev) and ev != "", do: ev |> String.split("|") |> Enum.reject(&(&1 == ""))
  defp format_evidence(_), do: []

  defp format_pipe_list(v) when is_binary(v) and v != "", do: v |> String.split("|") |> Enum.reject(&(&1 == ""))
  defp format_pipe_list(_), do: []

  defp format_response_time(nil), do: "—"
  defp format_response_time(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_response_time(ms) when is_binary(ms), do: "#{ms}ms"
  defp format_response_time(_), do: "—"

  defp freshness_label(enriched_at) when is_binary(enriched_at) do
    case DateTime.from_iso8601(enriched_at <> "Z") do
      {:ok, dt, _} ->
        hours = div(DateTime.diff(DateTime.utc_now(), dt, :second), 3600)
        cond do
          hours < 24 -> "< 24h"
          hours < 168 -> "< 7d"
          hours < 720 -> "< 30d"
          true -> "> 30d"
        end
      _ -> ""
    end
  end
  defp freshness_label(_), do: ""

  defp selected_values(filters, key) do
    val = Map.get(filters, key, "")
    val |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  end

  defp active_filter_count(filters) do
    Enum.count(filters, fn {_k, v} -> v != "" and not is_nil(v) end)
  end

  defp active_filter_tags(filters) do
    label_map = %{
      tech: "Tech", shopify_app: "Shopify Apps", country: "Country",
      business_model: "Business", industry: "Industry", revenue: "Revenue",
      employees: "Employees", language: "Language", freshness: "Freshness"
    }

    filters
    |> Enum.flat_map(fn {field, val} ->
      if field == :domain_search or val == "" or is_nil(val) do
        []
      else
        val
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(fn v -> %{field: field, value: v, label: Map.get(label_map, field, to_string(field))} end)
      end
    end)
    |> Enum.sort_by(& &1.label)
  end

  defp filter_active?(filters, field_atom) do
    val = Map.get(filters, field_atom, "")
    val != "" and not is_nil(val)
  end

  defp col_filter_summary(filters, field_atom) do
    val = Map.get(filters, field_atom, "")
    parts = val |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    case length(parts) do
      0 -> nil
      1 -> hd(parts)
      n -> "#{hd(parts)} +#{n - 1}"
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:total_pages, total_pages(assigns.total, assigns.per_page))

    ~H"""
    <div class="min-h-screen bg-[#0B0F19] text-gray-200 font-['Inter',system-ui,sans-serif]">
      <%!-- Header --%>
      <header class="border-b border-white/[0.06] bg-[#0F1628]">
        <div class="max-w-[1700px] mx-auto px-5 py-3.5 flex items-center justify-between">
          <.link navigate={~p"/dashboard"} class="flex items-center gap-3 hover:opacity-80 transition">
            <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-500 text-xs font-extrabold text-white">LS</div>
            <span class="text-white font-semibold text-[15px] tracking-tight">Dashboard</span>
          </.link>
          <div class="flex items-center gap-4 text-sm">
            <%!-- Rate limit indicator --%>
            <% rs = @rate_stats %>
            <% pct = if rs.limit > 0, do: rs.used * 100 / rs.limit, else: 0 %>
            <% bar_color = cond do
              pct >= 90 -> "bg-red-500"
              pct >= 70 -> "bg-amber-500"
              true -> "bg-emerald-500"
            end %>
            <% text_color = cond do
              pct >= 90 -> "text-red-400"
              pct >= 70 -> "text-amber-400"
              true -> "text-gray-400"
            end %>
            <div class="hidden md:flex items-center gap-2 group relative" title={"#{rs.remaining} of #{rs.limit} requests remaining this minute. Resets in #{rs.reset_in}s."}>
              <span class={"text-[11px] font-medium #{text_color}"}>
                <span class="text-white font-semibold"><%= rs.remaining %></span>/<%= rs.limit %> req/min
              </span>
              <div class="w-20 h-1.5 rounded-full bg-white/[0.06] overflow-hidden">
                <div class={"h-full #{bar_color} transition-all duration-500"} style={"width: #{min(pct, 100)}%"}></div>
              </div>
              <%!-- Tooltip --%>
              <div class="absolute top-full right-0 mt-2 w-56 bg-[#0B1020] border border-white/[0.08] rounded-lg p-3 text-xs text-gray-300 shadow-2xl opacity-0 group-hover:opacity-100 pointer-events-none transition-opacity z-50">
                <div class="font-semibold text-white mb-1">Rate Limit</div>
                <div><%= rs.used %> used / <%= rs.limit %> per minute</div>
                <div class="text-gray-500 mt-1">Resets in <%= rs.reset_in %>s</div>
                <%= cond do %>
                  <% @plan == "free" -> %>
                    <div class="mt-2 pt-2 border-t border-white/[0.06] text-amber-400">Upgrade to Starter for 30 req/min &#8594;</div>
                  <% @plan == "starter" -> %>
                    <div class="mt-2 pt-2 border-t border-white/[0.06] text-amber-400">Upgrade to Pro for 120 req/min &#8594;</div>
                  <% true -> %>
                <% end %>
              </div>
            </div>
            <%= case @plan do %>
              <% "free" -> %>
                <button phx-click="show_upgrade" class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-[11px] font-bold tracking-wide uppercase bg-amber-500/15 text-amber-400 ring-1 ring-amber-500/30 hover:bg-amber-500/25 hover:ring-amber-500/50 transition cursor-pointer animate-pulse">
                  <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 20 20"><path d="M9.049 2.927c.3-.921 1.603-.921 1.902 0l1.07 3.292a1 1 0 00.95.69h3.462c.969 0 1.371 1.24.588 1.81l-2.8 2.034a1 1 0 00-.364 1.118l1.07 3.292c.3.921-.755 1.688-1.54 1.118l-2.8-2.034a1 1 0 00-1.175 0l-2.8 2.034c-.784.57-1.838-.197-1.539-1.118l1.07-3.292a1 1 0 00-.364-1.118L2.98 8.72c-.783-.57-.38-1.81.588-1.81h3.461a1 1 0 00.951-.69l1.07-3.292z" /></svg>
                  FREE — Upgrade
                </button>
              <% "starter" -> %>
                <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-semibold tracking-wide uppercase bg-blue-500/15 text-blue-400 ring-1 ring-blue-500/20">
                  Starter
                </span>
              <% _ -> %>
                <span class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-semibold tracking-wide uppercase bg-emerald-500/15 text-emerald-400 ring-1 ring-emerald-500/20">
                  Pro
                </span>
            <% end %>
            <.link navigate={~p"/users/settings"} class="text-gray-500 hover:text-white transition inline-flex items-center gap-1.5 text-sm" title="Settings">
              <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
              <span>Settings</span>
            </.link>
            <.link href={~p"/users/log-out"} method="delete" class="text-gray-500 hover:text-white transition inline-flex items-center gap-1.5 text-sm" title="Log out">
              <.icon name="hero-arrow-right-start-on-rectangle" class="w-4 h-4" />
              <span>Log out</span>
            </.link>
          </div>
        </div>
      </header>

      <div class="max-w-[1700px] mx-auto px-5">
        <%!-- Hidden filter form for domain search --%>
        <form id="filter_form" phx-change="filter" class="hidden">
          <input type="hidden" name="tech" value={@filters.tech} />
          <input type="hidden" name="shopify_app" value={@filters.shopify_app} />
          <input type="hidden" name="country" value={@filters.country} />
          <input type="hidden" name="business_model" value={@filters.business_model} />
          <input type="hidden" name="industry" value={@filters.industry} />
          <input type="hidden" name="revenue" value={@filters.revenue} />
          <input type="hidden" name="employees" value={@filters.employees} />
          <input type="hidden" name="language" value={@filters.language} />
          <input type="hidden" name="domain_search" value={@filters.domain_search} />
          <input type="hidden" name="freshness" value={@filters.freshness} />
        </form>

        <%!-- Click-outside backdrop when a dropdown is open (pointer-events only, no layout impact) --%>
        <div
          phx-click="close_dropdown"
          class={"fixed inset-0 z-40 #{if @open_dropdown, do: "", else: "hidden"}"}
        ></div>

        <%!-- Toolbar --%>
        <div class="py-5 space-y-3">
          <%!-- Row 1: Domain search + active filter tags --%>
          <div class="flex items-center gap-2 flex-wrap min-h-[36px]">
            <div class="relative flex-shrink-0">
              <input type="text" name="domain_search" value={@filters.domain_search} form="filter_form" phx-debounce="400" placeholder="Search domain..."
                class="h-9 w-52 bg-[#141C30] border border-white/[0.08] rounded-lg px-3 pl-8 text-sm text-white placeholder-gray-500 focus:border-emerald-500/50 focus:ring-1 focus:ring-emerald-500/20 focus:outline-none transition" />
              <svg class="absolute left-2.5 top-2.5 w-4 h-4 text-gray-500" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z" /></svg>
              <%= if @filters.domain_search != "" do %>
                <button type="button" phx-click="clear_filter" phx-value-field="domain_search" class="absolute right-2 top-2 w-5 h-5 rounded-full bg-white/[0.08] hover:bg-white/[0.15] flex items-center justify-center text-gray-400 hover:text-white transition">
                  <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" /></svg>
                </button>
              <% end %>
            </div>

            <%!-- Active filter tags --%>
            <%= for tag <- active_filter_tags(@filters) do %>
              <div
                phx-click="remove_tag"
                phx-value-field={to_string(tag.field)}
                phx-value-value={tag.value}
                class="inline-flex items-center gap-1.5 h-7 pl-2.5 pr-2 bg-white/[0.06] border border-white/[0.10] rounded-full text-[12px] text-gray-300 font-medium cursor-pointer hover:border-red-500/30 hover:bg-red-500/[0.06] group/tag transition"
              >
                <span class="text-gray-500 text-[10px] uppercase"><%= tag.label %>:</span>
                <span><%= tag.value %></span>
                <svg class="w-3 h-3 text-gray-500 group-hover/tag:text-red-400 transition" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M6 18L18 6M6 6l12 12" /></svg>
              </div>
            <% end %>
            <%= if active_filter_count(@filters) > 1 do %>
              <button type="button" phx-click="clear_all_filters"
                class="inline-flex items-center gap-1 h-7 px-2.5 text-[11px] text-red-400/70 hover:text-red-400 font-medium transition">
                Clear all
              </button>
            <% end %>
          </div>

          <%!-- Row 2: Filter dropdown selectors --%>
          <div class="flex items-center gap-2 flex-wrap">
            <% shopify_selected = MapSet.member?(selected_values(@filters, :business_model), "Shopify") %>
            <%= for {field, label, icon, searchable} <- [
              {"tech", "Tech", "🔧", true},
              {"country", "Country", "🌍", true},
              {"business_model", "Business", "🏢", true},
              {"industry", "Industry", "🏭", true},
              {"revenue", "Revenue", "💰", true},
              {"employees", "Employees", "👥", true},
              {"language", "Language", "🗣️", true},
              {"freshness", "Freshness", "🕐", true}
            ] ++ (if shopify_selected, do: [{"shopify_app", "Shopify Apps", "🛍️", true}], else: []) do %>
              <.filter_dropdown
                field={field} label={label} icon={icon} searchable={searchable}
                filters={@filters}
                open_dropdown={@open_dropdown}
                dropdown_query={@dropdown_query}
                dropdown_options={@dropdown_options}
              />
            <% end %>
          </div>

          <%!-- Row 3: Info bar --%>
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4 text-sm">
              <span class="text-gray-400">
                <%= if @loading do %>
                  <span class="inline-flex items-center gap-1.5">
                    <span class="w-3 h-3 rounded-full border-2 border-emerald-500/40 border-t-emerald-500 animate-spin"></span>
                    Loading...
                  </span>
                <% else %>
                  <span class="text-white font-medium"><%= format_number(@total) %></span> results
                <% end %>
              </span>
              <%= if @query_ms && !@loading do %>
                <span class="text-gray-600 text-xs"><%= @query_ms %>ms</span>
              <% end %>
              <%= if active_filter_count(@filters) > 0 do %>
                <span class="text-gray-600 text-xs"><%= active_filter_count(@filters) %> filter<%= if active_filter_count(@filters) > 1, do: "s" %> active</span>
              <% end %>
            </div>
            <div class="flex items-center gap-4">
              <%= if @total_pages > 1 do %>
                <.pagination page={@page} total_pages={@total_pages} compact={true} />
              <% end %>
              <%= if @plan in ["starter", "pro"] do %>
                <a href={~p"/dashboard/export?" <> URI.encode_query(filter_params(@filters))}
                  class="inline-flex items-center gap-2 h-9 px-4 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg text-sm font-semibold shadow-lg shadow-emerald-500/20 transition">
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" /></svg>
                  Export CSV (<%= LS.Accounts.exports_remaining(@current_scope.user) %> rows left)
                </a>
              <% else %>
                <button phx-click="show_upgrade"
                  class="inline-flex items-center gap-2 h-9 px-4 bg-emerald-600/40 text-white/60 rounded-lg text-sm font-semibold opacity-60 cursor-pointer transition hover:opacity-80">
                  <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" /></svg>
                  Export CSV — Starter plan
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Main content --%>
        <div class="flex gap-4 pb-6">
          <%!-- Table --%>
          <div class={"flex-1 min-w-0 transition-all duration-200 #{if @expanded, do: "max-w-[60%]"}"}>
            <div class="rounded-xl border border-white/[0.06] bg-[#0F1628] overflow-hidden">
              <div class="overflow-x-auto dark-scrollbar">
                <table id="explorer-table" phx-hook="ResizableTable" class="w-full text-[13px] table-fixed">
                  <colgroup>
                    <col data-col="domain" style="width:140px" />
                    <col data-col="title" style="width:160px" />
                    <col data-col="tech" style="width:130px" />
                    <col data-col="apps" style="width:130px" />
                    <col data-col="country" style="width:80px" />
                    <col data-col="business" style="width:90px" />
                    <col data-col="industry" style="width:90px" />
                    <col data-col="revenue" style="width:90px" />
                    <col data-col="employees" style="width:80px" />
                    <col data-col="lang" style="width:55px" />
                    <col data-col="fresh" style="width:65px" />
                    <col data-col="speed" style="width:60px" />
                  </colgroup>
                  <thead>
                    <tr class="bg-[#0B1020] text-[11px] font-semibold uppercase tracking-wider">
                      <.col_header label="Domain" filter_field={:domain_search} filters={@filters} />
                      <.col_header label="Title" filter_field={nil} filters={@filters} />
                      <.col_header label="Tech" filter_field={:tech} filters={@filters} />
                      <.col_header label="Apps" filter_field={:shopify_app} filters={@filters} />
                      <.col_header label="Country" filter_field={:country} filters={@filters} />
                      <.col_header label="Business" filter_field={:business_model} filters={@filters} />
                      <.col_header label="Industry" filter_field={:industry} filters={@filters} />
                      <.col_header label="Revenue" filter_field={:revenue} filters={@filters} />
                      <.col_header label="Employees" filter_field={:employees} filters={@filters} />
                      <.col_header label="Lang" filter_field={:language} filters={@filters} />
                      <.col_header label="Fresh" filter_field={:freshness} filters={@filters} />
                      <.col_header label="Speed" filter_field={nil} filters={@filters} />
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-white/[0.04]">
                    <%= for row <- @results do %>
                      <tr phx-click="expand" phx-value-domain={row["domain"]}
                        class={"group cursor-pointer transition-colors hover:bg-white/[0.03] #{if @expanded == row["domain"], do: "bg-blue-500/[0.06] ring-1 ring-inset ring-blue-500/20"}"}>
                        <td class="px-4 py-2.5 font-medium text-blue-400 truncate"><%= row["domain"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-300"><%= row["http_title"] %></td>
                        <td class="px-3 py-2.5">
                          <div class="flex flex-wrap gap-1 overflow-hidden">
                            <%= for tech <- format_tech(row["http_tech"]) |> Enum.take(2) do %>
                              <span class="px-1.5 py-0.5 bg-purple-500/[0.08] text-purple-400/90 rounded text-[11px] font-medium truncate max-w-[80px]"><%= tech %></span>
                            <% end %>
                            <%= if length(format_tech(row["http_tech"])) > 2 do %>
                              <span class="text-gray-600 text-[11px]">+<%= length(format_tech(row["http_tech"])) - 2 %></span>
                            <% end %>
                          </div>
                        </td>
                        <td class="px-3 py-2.5">
                          <div class="flex flex-wrap gap-1 overflow-hidden">
                            <%= for app <- format_pipe_list(row["http_apps"]) |> Enum.take(2) do %>
                              <span class="px-1.5 py-0.5 bg-purple-500/[0.08] text-purple-400/90 rounded text-[11px] font-medium truncate max-w-[80px]"><%= app %></span>
                            <% end %>
                            <%= if length(format_pipe_list(row["http_apps"])) > 2 do %>
                              <span class="text-gray-600 text-[11px]">+<%= length(format_pipe_list(row["http_apps"])) - 2 %></span>
                            <% end %>
                          </div>
                        </td>
                        <td class="px-3 py-2.5 truncate text-gray-300"><%= country_flag(row["inferred_country"]) %> <%= row["inferred_country"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-400"><%= row["business_model"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-400"><%= row["industry"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-300"><%= row["estimated_revenue"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-400"><%= row["estimated_employees"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-400"><%= row["http_language"] %></td>
                        <td class="px-3 py-2.5 text-[11px] truncate text-gray-500"><%= freshness_label(row["enriched_at"]) %></td>
                        <td class="px-3 py-2.5 text-[11px] truncate text-gray-500"><%= format_response_time(row["http_response_time"]) %></td>
                      </tr>
                    <% end %>
                    <%= if @results == [] && !@loading do %>
                      <tr><td colspan="12" class="px-4 py-16 text-center text-gray-600">No results found. Try adjusting your filters.</td></tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          </div>

          <%!-- Detail panel --%>
          <%= if @expanded && @detail do %>
            <div class="w-[40%] flex-shrink-0">
              <div class="rounded-xl border border-white/[0.06] bg-[#0F1628] overflow-hidden sticky top-4">
                <%!-- Header --%>
                <div class="px-5 py-4 border-b border-white/[0.06] bg-[#0B1020]">
                  <div class="flex items-center justify-between">
                    <div class="flex items-center gap-2.5 min-w-0">
                      <div class="flex h-9 w-9 items-center justify-center rounded-lg bg-blue-500/10 text-blue-400 text-lg flex-shrink-0">🌐</div>
                      <div class="min-w-0 flex-1">
                        <a href={"https://#{@detail["domain"]}"} target="_blank" rel="noopener noreferrer" class="text-[15px] font-bold text-blue-400 hover:text-blue-300 hover:underline truncate block transition"><%= @detail["domain"] %></a>
                        <%= if @detail["http_title"] && @detail["http_title"] != "" do %>
                          <p class="text-[12px] text-gray-400 mt-0.5 line-clamp-2" title={@detail["http_title"]}><%= @detail["http_title"] %></p>
                        <% end %>
                      </div>
                    </div>
                    <button phx-click="expand" phx-value-domain={@expanded} class="flex items-center justify-center w-7 h-7 rounded-lg hover:bg-white/[0.06] text-gray-500 hover:text-white transition flex-shrink-0 ml-2">
                      <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" /></svg>
                    </button>
                  </div>
                </div>

                <%!-- Body --%>
                <div class="overflow-y-auto max-h-[calc(100vh-180px)] p-5 space-y-4 dark-scrollbar">
                  <%!-- Crawled timestamp --%>
                  <div class="flex items-center gap-2 text-[11px] text-gray-500 pb-1 border-b border-white/[0.04]">
                    <span>🕐</span>
                    <span>Crawled: <span class="text-gray-300"><%= format_datetime(@detail["enriched_at"]) %></span></span>
                  </div>

                  <%!-- Classification: Business + Industry + Confidence on one line --%>
                  <div class="grid grid-cols-3 gap-2.5">
                    <.detail_card icon="🏢" label="Business Model" value={@detail["business_model"]} />
                    <.detail_card icon="🏭" label="Industry" value={@detail["industry"]} />
                    <.detail_card icon="🎯" label="Confidence" value={format_pct(@detail["classification_confidence"])} />
                  </div>

                  <%!-- Revenue: Revenue + Employees + Confidence on one line --%>
                  <div class="grid grid-cols-3 gap-2.5">
                    <.detail_card icon="💰" label="Revenue" value={@detail["estimated_revenue"]} />
                    <.detail_card icon="👥" label="Employees" value={@detail["estimated_employees"]} />
                    <.detail_card icon="📊" label="Confidence" value={format_pct(@detail["revenue_confidence"])} />
                  </div>

                  <%!-- Country + Language --%>
                  <div class="grid grid-cols-2 gap-2.5">
                    <% inferred = LS.CountryInferrer.infer(@detail["ctl_tld"], @detail["http_language"], nil, @detail["bgp_asn_country"]) %>
                    <.detail_card icon="🌍" label="Country" value={if inferred != "", do: "#{country_flag(inferred)} #{country_name(inferred)}"} />
                    <.detail_card icon="🗣️" label="Language" value={if @detail["http_language"], do: language_name(@detail["http_language"])} />
                  </div>

                  <%!-- Tech stack — purple --%>
                  <.detail_section_badge icon="🔧" label="Tech Stack" badge={tech_section_badge(@detail)}>
                    <div class="flex flex-wrap gap-1.5">
                      <%= for tech <- format_tech(@detail["http_tech"]) do %>
                        <span class="px-2 py-1 bg-purple-500/[0.08] text-purple-400/90 rounded-md text-[11px] font-medium"><%= tech %></span>
                      <% end %>
                      <%= if format_tech(@detail["http_tech"]) == [] do %>
                        <span class="text-gray-600 text-xs">No data</span>
                      <% end %>
                    </div>
                  </.detail_section_badge>

                  <%!-- Apps — purple --%>
                  <%= if has_value?(@detail["http_apps"]) do %>
                    <.detail_section_badge icon="📦" label="Apps" badge={app_section_badge(@detail)}>
                      <div class="flex flex-wrap gap-1.5">
                        <%= for app <- format_tech(@detail["http_apps"]) do %>
                          <span class="px-2 py-1 bg-purple-500/[0.08] text-purple-400/90 rounded-md text-[11px] font-medium"><%= app %></span>
                        <% end %>
                      </div>
                    </.detail_section_badge>
                  <% end %>

                  <%!-- Revenue Evidence — gold/silver/bronze --%>
                  <%= if format_evidence(@detail["revenue_evidence"]) != [] do %>
                    <.detail_section_badge icon="📊" label="Revenue Evidence" badge={nil}>
                      <div class="space-y-1.5">
                        <%= for item <- format_evidence(@detail["revenue_evidence"]) do %>
                          <% {tier, label} = parse_evidence_item(item) %>
                          <div class="flex items-center gap-2 text-[12px]">
                            <span class={evidence_tier_class(tier)}><%= evidence_tier_dot(tier) %></span>
                            <span class={evidence_tier_text_class(tier)}><%= label %></span>
                          </div>
                        <% end %>
                      </div>
                    </.detail_section_badge>
                  <% end %>

                  <%!-- HTTP --%>
                  <.detail_section_badge icon="🌐" label="HTTP" badge={nil}>
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="⚡" label="Response Time" value={format_response_time(@detail["http_response_time"])} />
                      <.detail_card icon="📡" label="Status" value={@detail["http_status"]} />
                      <.detail_card icon="📄" label="Content Type" value={friendly_content_type(@detail["http_content_type"])} />
                      <.detail_card icon="🏷️" label="Schema Type" value={@detail["http_schema_type"]} />
                    </div>
                    <%= if has_value?(@detail["http_meta_description"]) do %>
                      <div class="mt-2.5 bg-[#0B1020] rounded-lg p-3">
                        <div class="text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1">📝 Meta Description</div>
                        <p class="text-[12px] text-gray-300 line-clamp-3"><%= @detail["http_meta_description"] %></p>
                      </div>
                    <% end %>
                    <%= if has_value?(@detail["http_h1"]) do %>
                      <div class="mt-2.5 bg-[#0B1020] rounded-lg p-3">
                        <div class="text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1">🔤 H1</div>
                        <p class="text-[12px] text-gray-300"><%= @detail["http_h1"] %></p>
                      </div>
                    <% end %>
                    <%!-- Pages — blue, clickable --%>
                    <%= if has_value?(@detail["http_pages"]) do %>
                      <div class="mt-2.5 bg-[#0B1020] rounded-lg p-3">
                        <div class="text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1">📑 Pages</div>
                        <div class="flex flex-wrap gap-1.5">
                          <%= for page <- format_pipe_list(@detail["http_pages"]) |> Enum.take(10) do %>
                            <a href={"https://#{@detail["domain"]}#{page}"} target="_blank" rel="noopener noreferrer"
                              class="px-2 py-0.5 bg-blue-500/[0.06] text-blue-400 hover:text-blue-300 hover:bg-blue-500/[0.12] rounded text-[11px] transition"><%= page %></a>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </.detail_section_badge>

                  <%!-- Emails — blue --%>
                  <%= if has_value?(@detail["http_emails"]) do %>
                    <.detail_section_badge icon="📧" label="Emails" badge={nil}>
                      <div class="space-y-1">
                        <%= for email <- format_pipe_list(@detail["http_emails"]) do %>
                          <div class="text-[12px] text-blue-400"><%= email %></div>
                        <% end %>
                      </div>
                    </.detail_section_badge>
                  <% end %>

                  <%!-- DNS --%>
                  <.detail_section_badge icon="🔍" label="DNS" badge={dns_section_badge(@detail)}>
                    <%= if has_value?(@detail["dns_mx"]) do %>
                      <% provider = mx_provider(@detail["dns_mx"]) %>
                      <%= if provider do %>
                        <div class="flex items-center gap-2 mb-2.5 bg-[#0B1020] rounded-lg px-3 py-2">
                          <span class="text-[11px] text-gray-500">📬 Mail Provider</span>
                          <span class="text-[13px] font-semibold text-white"><%= provider %></span>
                        </div>
                      <% end %>
                    <% end %>
                    <%!-- SPF and DKIM info derived from TXT --%>
                    <% spf = parse_spf(@detail["dns_txt"]) %>
                    <% dkim = parse_dkim(@detail["dns_txt"]) %>
                    <%= if spf || dkim do %>
                      <div class="grid grid-cols-2 gap-2.5 mb-2.5">
                        <%= if spf do %>
                          <div class="bg-[#0B1020] rounded-lg p-3">
                            <div class="flex items-center justify-between text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1.5">
                              <span>🛡️ SPF</span>
                              <span class={badge_class(spf.tier)}><%= spf.emoji %> <%= badge_label(spf.tier) %></span>
                            </div>
                            <div class="text-[12px] text-gray-300"><%= spf.summary %></div>
                          </div>
                        <% end %>
                        <%= if dkim do %>
                          <div class="bg-[#0B1020] rounded-lg p-3">
                            <div class="flex items-center justify-between text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1.5">
                              <span>🔐 DKIM/DMARC</span>
                              <span class={badge_class(dkim.tier)}><%= dkim.emoji %> <%= badge_label(dkim.tier) %></span>
                            </div>
                            <div class="text-[12px] text-gray-300"><%= dkim.summary %></div>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🅰️" label="A Record" value={@detail["dns_a"]} />
                      <.detail_card icon="6️⃣" label="AAAA Record" value={@detail["dns_aaaa"]} />
                      <.detail_card icon="📮" label="MX Record" value={format_mx_short(@detail["dns_mx"])} />
                      <.detail_card icon="↪️" label="CNAME" value={@detail["dns_cname"]} />
                    </div>
                    <%!-- TXT records — expandable --%>
                    <%= if has_value?(@detail["dns_txt"]) do %>
                      <details class="mt-2.5 bg-[#0B1020] rounded-lg p-3 group">
                        <summary class="cursor-pointer text-[10px] text-gray-500 uppercase tracking-wider font-semibold hover:text-gray-300 transition flex items-center justify-between">
                          <span>📝 TXT Records (<%= length(format_pipe_list(@detail["dns_txt"])) %>)</span>
                          <span class="text-gray-600 group-open:rotate-90 transition-transform">▸</span>
                        </summary>
                        <div class="mt-2 space-y-1.5">
                          <%= for txt <- format_pipe_list(@detail["dns_txt"]) do %>
                            <div class="text-[11px] text-gray-400 font-mono break-all bg-white/[0.02] rounded px-2 py-1.5"><%= txt %></div>
                          <% end %>
                        </div>
                      </details>
                    <% end %>
                  </.detail_section_badge>

                  <%!-- Network / BGP --%>
                  <.detail_section_badge icon="📡" label="Network (BGP)" badge={network_section_badge(@detail)}>
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🔢" label="IP Address" value={@detail["bgp_ip"]} />
                      <.detail_card icon="#️⃣" label="ASN Number" value={@detail["bgp_asn_number"]} />
                      <.detail_card icon="🏢" label="ASN Org" value={@detail["bgp_asn_org"]} />
                      <.detail_card icon="🌐" label="ASN Prefix" value={@detail["bgp_asn_prefix"]} />
                    </div>
                  </.detail_section_badge>

                  <%!-- Domain Registration --%>
                  <.detail_section_badge icon="🏛️" label="Domain Registration" badge={domain_section_badge(@detail)}>
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="📅" label="Created" value={format_date(@detail["rdap_domain_created_at"])} />
                      <.detail_card icon="⏳" label="Expires" value={format_date(@detail["rdap_domain_expires_at"])} />
                      <.detail_card icon="🔄" label="Updated" value={format_date(@detail["rdap_domain_updated_at"])} />
                      <.detail_card icon="🏛️" label="Registrar" value={@detail["rdap_registrar"]} />
                      <.detail_card icon="📋" label="Status" value={@detail["rdap_status"]} />
                    </div>
                    <%= if has_value?(@detail["rdap_nameservers"]) do %>
                      <div class="mt-2.5 bg-[#0B1020] rounded-lg p-3">
                        <div class="text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1.5">🖥️ Nameservers</div>
                        <div class="flex flex-wrap gap-1.5">
                          <%= for ns <- format_pipe_list(@detail["rdap_nameservers"]) do %>
                            <span class="px-2 py-0.5 bg-white/[0.04] text-gray-400 rounded text-[11px]"><%= ns %></span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </.detail_section_badge>

                  <%!-- SSL / Certificates --%>
                  <.detail_section_badge icon="🔒" label="SSL / Certificates" badge={ssl_section_badge(@detail)}>
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🔒" label="SSL Issuer" value={@detail["ctl_issuer"]} />
                      <.detail_card icon="🌐" label="TLD" value={@detail["ctl_tld"]} />
                      <.detail_card icon="🔢" label="Subdomains" value={@detail["ctl_subdomain_count"]} />
                    </div>
                  </.detail_section_badge>

                  <%!-- Subdomain list — purple, clickable --%>
                  <%= if format_subdomains(@detail["ctl_subdomains"]) != [] do %>
                    <.detail_section_badge icon="🔗" label="Subdomain List" badge={nil}>
                      <div class="flex flex-wrap gap-1.5">
                        <%= for sub <- format_subdomains(@detail["ctl_subdomains"]) |> Enum.take(30) do %>
                          <a href={"https://#{sub}.#{@detail["domain"]}"} target="_blank" rel="noopener noreferrer"
                            class="px-2 py-1 bg-purple-500/[0.06] hover:bg-purple-500/[0.12] rounded-md text-[11px] transition">
                            <span class="text-purple-400"><%= sub %></span><span class="text-gray-400">.<%= @detail["domain"] %></span>
                          </a>
                        <% end %>
                        <%= if length(format_subdomains(@detail["ctl_subdomains"])) > 30 do %>
                          <span class="text-gray-600 text-[11px]">+<%= length(format_subdomains(@detail["ctl_subdomains"])) - 30 %> more</span>
                        <% end %>
                      </div>
                    </.detail_section_badge>
                  <% end %>

                  <%!-- Rankings --%>
                  <.detail_section_badge icon="📈" label="Rankings" badge={rankings_section_badge(@detail)}>
                    <div class="grid grid-cols-3 gap-2.5">
                      <.detail_card icon="📈" label="Tranco" value={format_rank(@detail["tranco_rank"])} />
                      <.detail_card icon="👑" label="Majestic" value={format_rank(@detail["majestic_rank"])} />
                      <.detail_card icon="🌐" label="Ref Subnets" value={@detail["majestic_ref_subnets"]} />
                    </div>
                  </.detail_section_badge>

                  <%!-- Reputation --%>
                  <%= if any_flag?(@detail) do %>
                    <.detail_section_badge icon="🛡️" label="Reputation" badge={nil}>
                      <div class="flex flex-wrap gap-2">
                        <.flag_badge label="Malware" value={@detail["is_malware"]} />
                        <.flag_badge label="Phishing" value={@detail["is_phishing"]} />
                        <.flag_badge label="Disposable Email" value={@detail["is_disposable_email"]} />
                      </div>
                    </.detail_section_badge>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Bottom pagination --%>
        <%= if @total_pages > 1 do %>
          <div class="pb-8 pt-2">
            <.pagination page={@page} total_pages={@total_pages} compact={false} />
          </div>
        <% end %>
      </div>

      <%!-- Discreet dashboard footer --%>
      <footer class="border-t border-white/[0.04] mt-4">
        <div class="max-w-[1700px] mx-auto px-5 py-5">
          <div class="flex flex-col md:flex-row items-center justify-between gap-3 text-[11px] text-gray-600">
            <div class="flex items-center gap-2">
              <div class="flex h-4 w-4 items-center justify-center rounded bg-emerald-500/80 text-[8px] font-extrabold text-white">LS</div>
              <span>© 2026 ListSignal · A <span class="text-gray-500">ListSignal Pte Ltd</span> company, Singapore</span>
            </div>
            <div class="flex items-center gap-4">
              <a href="/features" class="hover:text-gray-400 transition">Features</a>
              <a href="/pricing" class="hover:text-gray-400 transition">Pricing</a>
              <a href="/api/tools/lookup" class="hover:text-gray-400 transition">API</a>
              <a href="/privacy" class="hover:text-gray-400 transition">Privacy</a>
              <a href="/terms" class="hover:text-gray-400 transition">Terms</a>
            </div>
          </div>
        </div>
      </footer>

      <%!-- Upgrade modal --%>
      <%= if @show_upgrade do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" phx-click="close_upgrade">
          <div class="bg-[#0F1628] border border-white/[0.08] rounded-2xl p-7 max-w-2xl w-full mx-4 shadow-2xl" phx-click-away="close_upgrade">
            <h3 class="text-lg font-bold text-white mb-2">Unlock more with ListSignal</h3>
            <p class="text-gray-400 text-sm mb-6">Choose the plan that fits your needs.</p>
            <div class="grid grid-cols-2 gap-4">
              <%!-- Starter card --%>
              <div class="border border-blue-500/20 rounded-xl p-5 bg-blue-500/[0.03]">
                <h4 class="font-semibold text-blue-400 text-sm">Starter</h4>
                <p class="text-3xl font-bold text-white mt-1">$39<span class="text-sm text-gray-500 font-normal">/mo</span></p>
                <ul class="text-sm text-gray-400 mt-3 space-y-1.5">
                  <li class="flex items-center gap-2"><span class="text-blue-400">&#10003;</span> Export up to 500 rows/mo</li>
                  <li class="flex items-center gap-2"><span class="text-blue-400">&#10003;</span> All filters unlocked</li>
                  <li class="flex items-center gap-2"><span class="text-blue-400">&#10003;</span> Contact emails visible</li>
                  <li class="flex items-center gap-2"><span class="text-blue-400">&#10003;</span> 30 searches/min</li>
                </ul>
                <form action={~p"/subscription/checkout/starter/monthly"} method="post" class="mt-5">
                  <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                  <button type="submit" class="w-full bg-blue-600 hover:bg-blue-500 text-white rounded-lg px-4 py-2.5 text-sm font-semibold shadow-lg shadow-blue-500/25 transition">
                    Subscribe to Starter &#8594;
                  </button>
                </form>
              </div>
              <%!-- Pro card --%>
              <div class="border border-emerald-500/20 rounded-xl p-5 bg-emerald-500/[0.03] relative">
                <span class="absolute -top-2.5 right-4 bg-accent text-white px-2.5 py-0.5 rounded-full text-[9px] font-bold uppercase tracking-wider">Recommended</span>
                <h4 class="font-semibold text-emerald-400 text-sm">Pro</h4>
                <p class="text-3xl font-bold text-white mt-1">$99<span class="text-sm text-gray-500 font-normal">/mo</span></p>
                <ul class="text-sm text-gray-400 mt-3 space-y-1.5">
                  <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> Export up to 5,000 rows/mo</li>
                  <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> 120 searches/min</li>
                  <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> Priority support</li>
                  <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> API access <span class="text-white/30 text-[9px] ml-1">(soon)</span></li>
                </ul>
                <form action={~p"/subscription/checkout/pro/monthly"} method="post" class="mt-5">
                  <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                  <button type="submit" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg px-4 py-2.5 text-sm font-semibold shadow-lg shadow-emerald-500/25 transition">
                    Subscribe to Pro &#8594;
                  </button>
                </form>
              </div>
            </div>
            <button phx-click="close_upgrade" class="mt-4 text-sm text-gray-600 hover:text-gray-400 w-full text-center transition">Maybe later</button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Components ──

  defp col_header(assigns) do
    active = if assigns.filter_field, do: filter_active?(assigns.filters, assigns.filter_field), else: false
    summary = if assigns.filter_field, do: col_filter_summary(assigns.filters, assigns.filter_field), else: nil

    assigns = assigns |> assign(:active, active) |> assign(:summary, summary)

    ~H"""
    <th class="px-3 py-3 text-left relative group/th select-none">
      <span class={"inline-flex items-center gap-1 #{if @active, do: "text-white", else: "text-gray-500"}"}>
        <%= @label %>
        <%= if @summary do %>
          <span class="text-[9px] font-bold bg-white/[0.10] text-gray-300 rounded px-1 py-0.5 normal-case max-w-[60px] truncate" title={@summary}><%= @summary %></span>
        <% end %>
      </span>
      <%!-- Resize handle --%>
      <div class="col-resize-handle absolute right-0 top-0 bottom-0 w-1.5 cursor-col-resize bg-transparent hover:bg-white/20 transition-colors"></div>
    </th>
    """
  end

  defp filter_dropdown(assigns) do
    field = assigns.field
    field_atom = String.to_existing_atom(field)
    selected = selected_values(assigns.filters, field_atom)
    count = MapSet.size(selected)
    is_open = assigns.open_dropdown == field

    assigns =
      assigns
      |> assign(:selected, selected)
      |> assign(:count, count)
      |> assign(:is_open, is_open)

    ~H"""
    <div class="relative">
      <%!-- Trigger button --%>
      <button
        type="button"
        phx-click="open_dropdown"
        phx-value-field={@field}
        class={"inline-flex items-center gap-1.5 h-9 px-3 rounded-lg border text-sm transition " <>
          if(@count > 0,
            do: "bg-white/[0.06] border-white/[0.15] text-white",
            else: "bg-[#141C30] border-white/[0.08] text-gray-400 hover:border-white/[0.15] hover:text-gray-300"
          )}
      >
        <span class="text-xs"><%= @icon %></span>
        <span class="font-medium"><%= @label %></span>
        <%= if @count > 0 do %>
          <span class="flex items-center justify-center w-[18px] h-[18px] rounded-full bg-emerald-500 text-[10px] font-bold text-white"><%= @count %></span>
        <% end %>
        <svg class={"w-3.5 h-3.5 transition #{if @is_open, do: "rotate-180"}"} fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" /></svg>
      </button>

      <%!-- Dropdown panel — z-50 so it sits above the z-40 backdrop --%>
      <%= if @is_open do %>
        <div class="absolute top-full left-0 mt-1.5 w-64 bg-[#141C30] border border-white/[0.08] rounded-xl shadow-2xl shadow-black/40 z-50 overflow-hidden">
          <%!-- Search --%>
          <%= if @searchable do %>
            <div class="p-2 border-b border-white/[0.06]">
              <input type="text" value={@dropdown_query} phx-keyup="dropdown_search" phx-debounce="200"
                placeholder={"Search #{String.downcase(@label)}..."}
                class="w-full h-8 bg-[#0B0F19] border border-white/[0.08] rounded-lg px-3 text-sm text-white placeholder-gray-600 focus:border-emerald-500/50 focus:outline-none"
                autofocus />
            </div>
          <% end %>

          <%!-- Options --%>
          <div class="max-h-72 overflow-y-auto" style="scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.08) transparent;">
            <%= for option <- @dropdown_options do %>
              <% checked = MapSet.member?(@selected, option) %>
              <div
                phx-click="select_option"
                phx-value-field={@field}
                phx-value-value={option}
                class={"flex items-center gap-2.5 w-full px-3 py-2 text-sm text-left transition cursor-pointer select-none " <>
                  if(checked, do: "bg-white/[0.04]", else: "hover:bg-white/[0.03]")}
              >
                <span class={"flex items-center justify-center w-4 h-4 rounded flex-shrink-0 border transition " <>
                  if(checked,
                    do: "bg-blue-500 border-blue-500",
                    else: "border-gray-600 bg-transparent"
                  )}>
                  <%= if checked do %>
                    <svg class="w-3 h-3 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" /></svg>
                  <% end %>
                </span>
                <%!-- Custom rendering for country (flag + name + code) and language (name + code) --%>
                <%= if @field == "country" do %>
                  <span class={"flex-1 flex items-center justify-between gap-1 #{if checked, do: "text-white font-medium", else: "text-gray-300"}"}>
                    <span class="truncate"><%= country_flag(option) %> <%= country_name(option) %></span>
                    <span class="text-gray-500 text-xs flex-shrink-0"><%= option %></span>
                  </span>
                <% else %>
                  <%= if @field == "language" do %>
                    <span class={"flex-1 flex items-center justify-between gap-1 #{if checked, do: "text-white font-medium", else: "text-gray-300"}"}>
                      <span class="truncate"><%= language_name(option) %></span>
                      <span class="text-gray-500 text-xs flex-shrink-0"><%= option %></span>
                    </span>
                  <% else %>
                    <span class={"truncate #{if checked, do: "text-white font-medium", else: "text-gray-300"}"}><%= option %></span>
                  <% end %>
                <% end %>
              </div>
            <% end %>
            <%= if @dropdown_options == [] do %>
              <div class="px-3 py-4 text-sm text-gray-600 text-center">No options found</div>
            <% end %>
          </div>

          <%!-- Footer --%>
          <%= if @count > 0 do %>
            <div class="border-t border-white/[0.06] px-3 py-2 flex items-center justify-between">
              <span class="text-[11px] text-gray-500"><%= @count %> selected</span>
              <button type="button" phx-click="clear_filter" phx-value-field={@field}
                class="text-[11px] text-red-400/70 hover:text-red-400 font-medium transition">
                Clear all
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp detail_card(assigns) do
    ~H"""
    <div class="bg-[#0B1020] rounded-lg p-3">
      <div class="flex items-center gap-1.5 text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1.5">
        <span><%= @icon %></span><%= @label %>
      </div>
      <div class="text-[13px] font-medium text-gray-200 truncate" title={to_string(@value || "")}>
        <%= if has_value?(@value), do: @value, else: "—" %>
      </div>
    </div>
    """
  end

  defp detail_section_badge(assigns) do
    ~H"""
    <div class="bg-[#0B1020]/50 rounded-lg p-3.5 border border-white/[0.03]">
      <div class="flex items-center justify-between mb-2.5">
        <div class="flex items-center gap-1.5 text-[10px] text-gray-600 uppercase tracking-wider font-semibold">
          <span><%= @icon %></span><%= @label %>
        </div>
        <%= if @badge do %>
          <span class={badge_class(@badge)}><%= badge_label(@badge) %></span>
        <% end %>
      </div>
      <%= render_slot(@inner_block) %>
    </div>
    """
  end

  defp flag_badge(assigns) do
    flagged = assigns.value in [true, 1, "1", "true"]
    assigns = assign(assigns, :flagged, flagged)

    ~H"""
    <span class={"inline-flex items-center gap-1 px-2 py-1 rounded-md text-[11px] font-medium " <>
      if(@flagged, do: "bg-red-500/10 text-red-400", else: "bg-green-500/10 text-green-400/70")}>
      <%= if @flagged, do: "⚠️", else: "✅" %>
      <%= @label %>
    </span>
    """
  end

  defp pagination(assigns) do
    ~H"""
    <div class={"flex items-center gap-1.5 #{if @compact, do: "text-sm", else: "justify-center text-sm"}"}>
      <%= if @page > 1 do %>
        <button phx-click="page" phx-value-page={@page - 1}
          class="inline-flex items-center gap-1 px-3 py-1.5 bg-[#141C30] border border-white/[0.08] rounded-lg text-gray-400 hover:text-white hover:border-white/[0.15] transition">
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" /></svg>
          <span :if={!@compact}>Prev</span>
        </button>
      <% end %>
      <%= for p <- pagination_range(@page, @total_pages) do %>
        <%= if p == :gap do %>
          <span class="px-1.5 text-gray-600">...</span>
        <% else %>
          <button phx-click="page" phx-value-page={p}
            class={"inline-flex items-center justify-center min-w-[32px] h-8 px-2 rounded-lg text-sm font-medium transition " <>
              if(p == @page,
                do: "bg-emerald-600 text-white shadow-md shadow-emerald-500/25",
                else: "text-gray-500 hover:text-white hover:bg-white/[0.04]"
              )}>
            <%= p %>
          </button>
        <% end %>
      <% end %>
      <%= if @page < @total_pages do %>
        <button phx-click="page" phx-value-page={@page + 1}
          class="inline-flex items-center gap-1 px-3 py-1.5 bg-[#141C30] border border-white/[0.08] rounded-lg text-gray-400 hover:text-white hover:border-white/[0.15] transition">
          <span :if={!@compact}>Next</span>
          <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7" /></svg>
        </button>
      <% end %>
      <%= if !@compact do %>
        <span class="text-gray-600 ml-2 text-xs">Page <%= @page %> of <%= @total_pages %></span>
      <% end %>
    </div>
    """
  end

  # ── Helpers ──

  defp pagination_range(_current, total) when total <= 7, do: Enum.to_list(1..max(total, 1))

  defp pagination_range(current, total) do
    cond do
      current <= 4 -> Enum.to_list(1..5) ++ [:gap, total]
      current >= total - 3 -> [1, :gap] ++ Enum.to_list((total - 4)..total)
      true -> [1, :gap] ++ Enum.to_list((current - 1)..(current + 1)) ++ [:gap, total]
    end
  end

  defp has_value?(nil), do: false
  defp has_value?(""), do: false
  defp has_value?(0), do: false
  defp has_value?("0"), do: false
  defp has_value?(_), do: true

  defp any_flag?(detail) do
    Enum.any?(["is_malware", "is_phishing", "is_disposable_email"], fn k ->
      detail[k] in [true, 1, "1", "true"]
    end)
  end

  defp format_number(n) when is_integer(n) do
    n |> Integer.to_string() |> String.graphemes() |> Enum.reverse() |> Enum.chunk_every(3) |> Enum.join(",") |> String.reverse()
  end
  defp format_number(n), do: to_string(n)

  defp format_rank(nil), do: nil
  defp format_rank(0), do: nil
  defp format_rank(""), do: nil
  defp format_rank("0"), do: nil
  defp format_rank(n) when is_integer(n), do: "##{format_number(n)}"
  defp format_rank(n) when is_binary(n), do: "##{n}"
  defp format_rank(_), do: nil

  defp format_date(nil), do: nil
  defp format_date(""), do: nil
  defp format_date(dt) when is_binary(dt) do
    case Date.from_iso8601(String.slice(dt, 0, 10)) do
      {:ok, d} -> Calendar.strftime(d, "%b %d, %Y")
      _ -> dt
    end
  end
  defp format_date(_), do: nil

  defp format_datetime(nil), do: "—"
  defp format_datetime(""), do: "—"
  defp format_datetime(dt) when is_binary(dt) do
    clean = dt |> String.replace("T", " ") |> String.replace("Z", "")
    case NaiveDateTime.from_iso8601(clean) do
      {:ok, ndt} -> Calendar.strftime(ndt, "%b %d, %Y %H:%M UTC")
      _ -> dt
    end
  end
  defp format_datetime(_), do: "—"

  defp format_pct(nil), do: nil
  defp format_pct(""), do: nil
  defp format_pct(v) when is_float(v), do: "#{round(v * 100)}%"
  defp format_pct(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> "#{round(f * 100)}%"
      :error -> v
    end
  end
  defp format_pct(v) when is_integer(v), do: "#{v}%"
  defp format_pct(_), do: nil

  defp filter_params(filters) do
    filters |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end) |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  # Badge system: :gold, :silver, :bronze
  defp badge_class(:gold), do: "px-2 py-0.5 rounded-full text-[9px] font-bold uppercase bg-amber-400/15 text-amber-400 ring-1 ring-amber-400/30"
  defp badge_class(:silver), do: "px-2 py-0.5 rounded-full text-[9px] font-bold uppercase bg-gray-300/10 text-gray-300 ring-1 ring-gray-300/20"
  defp badge_class(:bronze), do: "px-2 py-0.5 rounded-full text-[9px] font-bold uppercase bg-orange-500/10 text-orange-400 ring-1 ring-orange-400/25"
  defp badge_class(_), do: ""

  defp badge_label(:gold), do: "Gold"
  defp badge_label(:silver), do: "Silver"
  defp badge_label(:bronze), do: "Bronze"
  defp badge_label(_), do: ""

  # MX provider detection
  defp mx_provider(nil), do: nil
  defp mx_provider(""), do: nil
  defp mx_provider(mx) when is_binary(mx) do
    lower = String.downcase(mx)
    cond do
      String.contains?(lower, "google") or String.contains?(lower, "aspmx") -> "Google Workspace"
      String.contains?(lower, "outlook") or String.contains?(lower, "microsoft") -> "Microsoft 365"
      String.contains?(lower, "protonmail") or String.contains?(lower, "proton") -> "Proton Mail"
      String.contains?(lower, "zoho") -> "Zoho Mail"
      String.contains?(lower, "mimecast") -> "Mimecast"
      String.contains?(lower, "barracuda") -> "Barracuda"
      String.contains?(lower, "pphosted") or String.contains?(lower, "proofpoint") -> "Proofpoint"
      String.contains?(lower, "yahoodns") or String.contains?(lower, "yahoo") -> "Yahoo Mail"
      String.contains?(lower, "secureserver") or String.contains?(lower, "godaddy") -> "GoDaddy Email"
      String.contains?(lower, "ovh") -> "OVH Mail"
      true -> nil
    end
  end
  defp mx_provider(_), do: nil

  defp format_mx_short(nil), do: nil
  defp format_mx_short(""), do: nil
  defp format_mx_short(mx) when is_binary(mx) do
    mx |> String.split("|") |> hd() |> String.trim()
  end
  defp format_mx_short(_), do: nil

  # Friendly content type: "text/html; charset=utf-8" -> "HTML"
  defp friendly_content_type(nil), do: nil
  defp friendly_content_type(""), do: nil
  defp friendly_content_type(ct) when is_binary(ct) do
    lower = String.downcase(ct)
    cond do
      String.contains?(lower, "text/html") -> "HTML"
      String.contains?(lower, "application/xhtml") -> "XHTML"
      String.contains?(lower, "application/json") -> "JSON"
      String.contains?(lower, "application/xml") or String.contains?(lower, "text/xml") -> "XML"
      String.contains?(lower, "application/pdf") -> "PDF"
      String.contains?(lower, "text/plain") -> "Text"
      String.contains?(lower, "text/css") -> "CSS"
      String.contains?(lower, "javascript") -> "JavaScript"
      String.contains?(lower, "image/") -> "Image"
      String.contains?(lower, "video/") -> "Video"
      String.contains?(lower, "audio/") -> "Audio"
      true -> ct |> String.split(";") |> hd() |> String.trim()
    end
  end
  defp friendly_content_type(_), do: nil

  # SPF parser: returns %{tier, emoji, summary} or nil
  defp parse_spf(nil), do: nil
  defp parse_spf(""), do: nil
  defp parse_spf(txt) when is_binary(txt) do
    spf_record =
      txt
      |> String.split("|")
      |> Enum.find(fn r -> String.starts_with?(String.trim(r), "v=spf1") end)

    case spf_record do
      nil -> nil
      record ->
        includes = Regex.scan(~r/include:(\S+)/, record) |> length()
        has_all = String.contains?(record, "-all") or String.contains?(record, "~all")
        strict = String.contains?(record, "-all")

        {tier, emoji, summary} =
          cond do
            includes >= 3 and strict -> {:gold, "🏆", "Advanced — #{includes} includes, strict (-all)"}
            includes >= 2 and has_all -> {:gold, "⭐", "Strong — #{includes} includes, #{if strict, do: "strict", else: "soft"}"}
            includes >= 1 and has_all -> {:silver, "✓", "Standard — #{includes} include(s), #{if strict, do: "strict", else: "soft"}"}
            has_all -> {:silver, "✓", "Basic — no includes, #{if strict, do: "strict", else: "soft"}"}
            true -> {:bronze, "⚠", "Weak — no qualifier"}
          end

        %{tier: tier, emoji: emoji, summary: summary}
    end
  end
  defp parse_spf(_), do: nil

  # DKIM/DMARC parser
  defp parse_dkim(nil), do: nil
  defp parse_dkim(""), do: nil
  defp parse_dkim(txt) when is_binary(txt) do
    records = String.split(txt, "|")
    dmarc = Enum.find(records, fn r -> String.contains?(r, "v=DMARC1") end)
    has_dkim = Enum.any?(records, fn r -> String.contains?(r, "v=DKIM1") or String.contains?(r, "k=rsa") end)

    cond do
      dmarc && String.contains?(dmarc, "p=reject") ->
        %{tier: :gold, emoji: "🏆", summary: "DMARC reject policy" <> if(has_dkim, do: " + DKIM", else: "")}

      dmarc && String.contains?(dmarc, "p=quarantine") ->
        %{tier: :gold, emoji: "⭐", summary: "DMARC quarantine" <> if(has_dkim, do: " + DKIM", else: "")}

      dmarc && String.contains?(dmarc, "p=none") ->
        %{tier: :silver, emoji: "✓", summary: "DMARC monitoring only" <> if(has_dkim, do: " + DKIM", else: "")}

      has_dkim ->
        %{tier: :silver, emoji: "✓", summary: "DKIM configured"}

      true -> nil
    end
  end
  defp parse_dkim(_), do: nil

  # Evidence parsing: "tranco:top_100k:25741->mid_market" -> {:gold, "Tranco #25,741 — Mid Market"}
  defp parse_evidence_item(item) when is_binary(item) do
    case String.split(item, [":", "→", "->"], parts: 4) do
      [signal, tier, val, estimate] ->
        badge = evidence_signal_tier(signal, tier)
        label = "#{humanize_signal(signal)} #{humanize_val(val)} — #{humanize_estimate(estimate)}"
        {badge, label}
      [signal, tier, val_or_est] ->
        badge = evidence_signal_tier(signal, tier)
        {badge, "#{humanize_signal(signal)} #{humanize_val(tier)} — #{humanize_estimate(val_or_est)}"}
      _ -> {:bronze, item}
    end
  end
  defp parse_evidence_item(item), do: {:bronze, to_string(item)}

  defp evidence_signal_tier(signal, tier) do
    t = String.downcase(tier)
    cond do
      String.contains?(t, "enterprise") or String.contains?(t, "top_10k") or String.contains?(t, "top_50k") -> :gold
      String.contains?(t, "mid_market") or String.contains?(t, "top_100k") or String.contains?(t, "top_500k") -> :gold
      String.contains?(t, "small") or String.contains?(t, "top_1m") -> :silver
      String.contains?(t, "micro") or String.contains?(t, "basic") -> :bronze
      String.downcase(signal) in ~w(tranco majestic ref_subnets) -> :silver
      true -> :bronze
    end
  end

  defp humanize_signal(s) do
    case String.downcase(s) do
      "tranco" -> "Tranco"
      "majestic" -> "Majestic"
      "ref_subnets" -> "Ref Subnets"
      "ssl_issuer" -> "SSL"
      "mx" -> "Email"
      "spf_includes" -> "SPF"
      "tech_count" -> "Tech Stack"
      "app_count" -> "Apps"
      "cms" -> "CMS"
      "tools" -> "Tool"
      other -> other |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp humanize_val(v) do
    case Integer.parse(v) do
      {n, _} when n > 999 -> "##{format_number(n)}"
      {n, _} -> "#{n}"
      :error -> v |> String.replace("_", " ")
    end
  end

  defp humanize_estimate(e), do: e |> String.replace("_", " ") |> String.capitalize()

  defp evidence_tier_class(:gold), do: "w-2 h-2 rounded-full bg-amber-400 flex-shrink-0"
  defp evidence_tier_class(:silver), do: "w-2 h-2 rounded-full bg-gray-300 flex-shrink-0"
  defp evidence_tier_class(:bronze), do: "w-2 h-2 rounded-full bg-orange-500 flex-shrink-0"
  defp evidence_tier_class(_), do: "w-2 h-2 rounded-full bg-gray-600 flex-shrink-0"

  defp evidence_tier_dot(:gold), do: ""
  defp evidence_tier_dot(:silver), do: ""
  defp evidence_tier_dot(:bronze), do: ""
  defp evidence_tier_dot(_), do: ""

  defp evidence_tier_text_class(:gold), do: "text-amber-400 font-medium"
  defp evidence_tier_text_class(:silver), do: "text-gray-300"
  defp evidence_tier_text_class(:bronze), do: "text-orange-400/80"
  defp evidence_tier_text_class(_), do: "text-gray-500"

  # Section badges
  defp tech_section_badge(d) do
    count = length(format_tech(d["http_tech"]))
    cond do
      count >= 8 -> :gold
      count >= 4 -> :silver
      count >= 1 -> :bronze
      true -> nil
    end
  end

  defp app_section_badge(d) do
    count = length(format_pipe_list(d["http_apps"]))
    cond do
      count >= 5 -> :gold
      count >= 2 -> :silver
      count >= 1 -> :bronze
      true -> nil
    end
  end

  defp dns_section_badge(d) do
    mx = mx_provider(d["dns_mx"])
    cond do
      mx in ["Google Workspace", "Microsoft 365", "Proofpoint", "Mimecast"] -> :gold
      mx != nil -> :silver
      has_value?(d["dns_mx"]) -> :bronze
      true -> nil
    end
  end

  defp network_section_badge(d) do
    org = to_string(d["bgp_asn_org"]) |> String.downcase()
    cond do
      String.contains?(org, "amazon") or String.contains?(org, "aws") -> :gold
      String.contains?(org, "google") or String.contains?(org, "gcp") -> :gold
      String.contains?(org, "cloudflare") -> :gold
      String.contains?(org, "microsoft") or String.contains?(org, "azure") -> :gold
      String.contains?(org, "fastly") or String.contains?(org, "akamai") -> :silver
      String.contains?(org, "digitalocean") or String.contains?(org, "hetzner") -> :silver
      String.contains?(org, "ovh") or String.contains?(org, "linode") -> :silver
      has_value?(d["bgp_asn_org"]) -> :bronze
      true -> nil
    end
  end

  defp domain_section_badge(d) do
    registrar = to_string(d["rdap_registrar"]) |> String.downcase()
    has_dates = has_value?(d["rdap_domain_created_at"])
    cond do
      String.contains?(registrar, "markmonitor") or String.contains?(registrar, "csc") -> :gold
      String.contains?(registrar, "networksolutions") or String.contains?(registrar, "safenames") -> :gold
      has_dates and has_value?(d["rdap_registrar"]) -> :silver
      has_dates -> :bronze
      true -> nil
    end
  end

  defp ssl_section_badge(d) do
    sub_count = parse_int(d["ctl_subdomain_count"])
    issuer = to_string(d["ctl_issuer"]) |> String.downcase()
    cond do
      sub_count >= 20 or String.contains?(issuer, "digicert") or String.contains?(issuer, "globalsign") -> :gold
      sub_count >= 5 or String.contains?(issuer, "amazon") or String.contains?(issuer, "sectigo") -> :silver
      has_value?(d["ctl_issuer"]) -> :bronze
      true -> nil
    end
  end

  defp rankings_section_badge(d) do
    tranco = parse_int(d["tranco_rank"])
    majestic = parse_int(d["majestic_rank"])
    best = Enum.min([tranco || 999_999_999, majestic || 999_999_999])
    cond do
      best <= 100_000 -> :gold
      best <= 500_000 -> :silver
      best <= 2_000_000 -> :bronze
      true -> nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(n) when is_integer(n), do: n
  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end
  defp parse_int(_), do: nil

  @country_names %{
    "AD" => "Andorra", "AE" => "United Arab Emirates", "AF" => "Afghanistan", "AG" => "Antigua & Barbuda",
    "AL" => "Albania", "AM" => "Armenia", "AO" => "Angola", "AR" => "Argentina", "AT" => "Austria",
    "AU" => "Australia", "AZ" => "Azerbaijan", "BA" => "Bosnia", "BB" => "Barbados", "BD" => "Bangladesh",
    "BE" => "Belgium", "BG" => "Bulgaria", "BH" => "Bahrain", "BM" => "Bermuda", "BN" => "Brunei",
    "BO" => "Bolivia", "BR" => "Brazil", "BS" => "Bahamas", "BW" => "Botswana", "BY" => "Belarus",
    "BZ" => "Belize", "CA" => "Canada", "CD" => "DR Congo", "CH" => "Switzerland", "CI" => "Ivory Coast",
    "CL" => "Chile", "CM" => "Cameroon", "CN" => "China", "CO" => "Colombia", "CR" => "Costa Rica",
    "CU" => "Cuba", "CW" => "Curacao", "CY" => "Cyprus", "CZ" => "Czechia", "DE" => "Germany",
    "DK" => "Denmark", "DO" => "Dominican Republic", "DZ" => "Algeria", "EC" => "Ecuador", "EE" => "Estonia",
    "EG" => "Egypt", "ES" => "Spain", "ET" => "Ethiopia", "FI" => "Finland", "FJ" => "Fiji",
    "FR" => "France", "GA" => "Gabon", "GB" => "United Kingdom", "GE" => "Georgia", "GH" => "Ghana",
    "GR" => "Greece", "GT" => "Guatemala", "GU" => "Guam", "HK" => "Hong Kong", "HN" => "Honduras",
    "HR" => "Croatia", "HU" => "Hungary", "ID" => "Indonesia", "IE" => "Ireland", "IL" => "Israel",
    "IN" => "India", "IQ" => "Iraq", "IR" => "Iran", "IS" => "Iceland", "IT" => "Italy",
    "JM" => "Jamaica", "JO" => "Jordan", "JP" => "Japan", "KE" => "Kenya", "KG" => "Kyrgyzstan",
    "KH" => "Cambodia", "KR" => "South Korea", "KW" => "Kuwait", "KY" => "Cayman Islands", "KZ" => "Kazakhstan",
    "LA" => "Laos", "LB" => "Lebanon", "LI" => "Liechtenstein", "LK" => "Sri Lanka", "LT" => "Lithuania",
    "LU" => "Luxembourg", "LV" => "Latvia", "LY" => "Libya", "MA" => "Morocco", "MC" => "Monaco",
    "MD" => "Moldova", "ME" => "Montenegro", "MG" => "Madagascar", "MK" => "North Macedonia", "MM" => "Myanmar",
    "MN" => "Mongolia", "MO" => "Macau", "MT" => "Malta", "MU" => "Mauritius", "MV" => "Maldives",
    "MX" => "Mexico", "MY" => "Malaysia", "MZ" => "Mozambique", "NA" => "Namibia", "NG" => "Nigeria",
    "NI" => "Nicaragua", "NL" => "Netherlands", "NO" => "Norway", "NP" => "Nepal", "NZ" => "New Zealand",
    "OM" => "Oman", "PA" => "Panama", "PE" => "Peru", "PH" => "Philippines", "PK" => "Pakistan",
    "PL" => "Poland", "PR" => "Puerto Rico", "PS" => "Palestine", "PT" => "Portugal", "PY" => "Paraguay",
    "QA" => "Qatar", "RO" => "Romania", "RS" => "Serbia", "RU" => "Russia", "RW" => "Rwanda",
    "SA" => "Saudi Arabia", "SC" => "Seychelles", "SD" => "Sudan", "SE" => "Sweden", "SG" => "Singapore",
    "SI" => "Slovenia", "SK" => "Slovakia", "SN" => "Senegal", "SO" => "Somalia", "SV" => "El Salvador",
    "TH" => "Thailand", "TN" => "Tunisia", "TR" => "Turkey", "TT" => "Trinidad & Tobago", "TW" => "Taiwan",
    "TZ" => "Tanzania", "UA" => "Ukraine", "UG" => "Uganda", "US" => "United States", "UY" => "Uruguay",
    "UZ" => "Uzbekistan", "VE" => "Venezuela", "VG" => "British Virgin Islands", "VI" => "US Virgin Islands",
    "VN" => "Vietnam", "ZA" => "South Africa", "ZM" => "Zambia", "ZW" => "Zimbabwe"
  }

  defp country_name(code) when is_binary(code), do: Map.get(@country_names, String.upcase(code), code)
  defp country_name(_), do: ""

  @language_names %{
    "en" => "English", "fr" => "French", "de" => "German", "es" => "Spanish", "it" => "Italian",
    "pt" => "Portuguese", "nl" => "Dutch", "ru" => "Russian", "zh" => "Chinese", "ja" => "Japanese",
    "ko" => "Korean", "ar" => "Arabic", "hi" => "Hindi", "bn" => "Bengali", "pa" => "Punjabi",
    "tr" => "Turkish", "vi" => "Vietnamese", "th" => "Thai", "pl" => "Polish", "uk" => "Ukrainian",
    "ro" => "Romanian", "el" => "Greek", "cs" => "Czech", "sv" => "Swedish", "hu" => "Hungarian",
    "fi" => "Finnish", "da" => "Danish", "no" => "Norwegian", "sk" => "Slovak", "bg" => "Bulgarian",
    "hr" => "Croatian", "sr" => "Serbian", "sl" => "Slovenian", "lt" => "Lithuanian", "lv" => "Latvian",
    "et" => "Estonian", "ms" => "Malay", "id" => "Indonesian", "tl" => "Filipino", "he" => "Hebrew",
    "fa" => "Persian", "ur" => "Urdu", "sw" => "Swahili", "af" => "Afrikaans", "ca" => "Catalan",
    "gl" => "Galician", "eu" => "Basque", "is" => "Icelandic", "ga" => "Irish", "cy" => "Welsh",
    "sq" => "Albanian", "mk" => "Macedonian", "bs" => "Bosnian", "mt" => "Maltese", "ka" => "Georgian",
    "hy" => "Armenian", "az" => "Azerbaijani", "kk" => "Kazakh", "uz" => "Uzbek", "mn" => "Mongolian",
    "km" => "Khmer", "lo" => "Lao", "my" => "Burmese", "ne" => "Nepali", "si" => "Sinhala",
    "am" => "Amharic", "ta" => "Tamil", "te" => "Telugu", "kn" => "Kannada", "ml" => "Malayalam",
    "mr" => "Marathi", "gu" => "Gujarati"
  }

  defp language_name(code) when is_binary(code), do: Map.get(@language_names, String.downcase(code), code)
  defp language_name(_), do: ""

end
