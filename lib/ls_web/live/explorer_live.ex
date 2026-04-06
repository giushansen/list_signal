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
        dropdown_options: []
      )

    if connected?(socket) do
      RateLimiter.init()
      send(self(), :load_data)
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
  defp fetch_dropdown_options("shopify_app", query), do: fetch_apps(query)
  defp fetch_dropdown_options("country", query), do: fetch_distinct("bgp_asn_country", query)
  defp fetch_dropdown_options("language", query), do: fetch_distinct("http_language", query)
  defp fetch_dropdown_options("business_model", _query), do: Explorer.business_models()
  defp fetch_dropdown_options("industry", _query), do: Explorer.industries()
  defp fetch_dropdown_options("revenue", _query), do: ["<$1M", "$1M-$10M", "$10M-$50M", "$50M-$100M", "$100M-$1B", "$1B+"]
  defp fetch_dropdown_options("employees", _query), do: ["1-10", "11-50", "51-200", "201-500", "501-5000", "5001+"]
  defp fetch_dropdown_options("freshness", _query), do: ["24h", "7d", "30d"]
  defp fetch_dropdown_options(_, _), do: []

  defp fetch_techs(query) do
    case Explorer.distinct_techs(query, 30) do
      {:ok, techs} -> techs
      _ -> []
    end
  end

  defp fetch_apps(query) do
    case Explorer.distinct_apps(query, 30) do
      {:ok, apps} -> apps
      _ -> []
    end
  end

  defp fetch_distinct(column, query) do
    case Explorer.distinct_values(column, query, 30) do
      {:ok, values} -> values
      _ -> []
    end
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
        assign(socket, results: results, total: total, loading: false, query_ms: query_ms)

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
          <div class="flex items-center gap-3">
            <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-500 text-xs font-extrabold text-white">LS</div>
            <span class="text-white font-semibold text-[15px] tracking-tight">Explorer</span>
          </div>
          <div class="flex items-center gap-4 text-sm">
            <span class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-[11px] font-semibold tracking-wide uppercase #{plan_badge_class(@plan)}"}>
              <%= @plan %>
            </span>
            <.link navigate={~p"/users/settings"} class="text-gray-500 hover:text-white transition text-sm">Settings</.link>
            <.link href={~p"/users/log-out"} method="delete" class="text-gray-500 hover:text-white transition text-sm">Log out</.link>
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
                class="inline-flex items-center gap-1.5 h-7 pl-2.5 pr-2 bg-emerald-500/[0.1] border border-emerald-500/20 rounded-full text-[12px] text-emerald-400 font-medium cursor-pointer hover:border-red-500/30 hover:bg-red-500/[0.06] group/tag transition"
              >
                <span class="text-emerald-600/70 text-[10px] uppercase"><%= tag.label %>:</span>
                <span><%= tag.value %></span>
                <svg class="w-3 h-3 text-emerald-500/50 group-hover/tag:text-red-400 transition" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M6 18L18 6M6 6l12 12" /></svg>
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
            <%= for {field, label, icon, searchable} <- [
              {"tech", "Tech", "🔧", true},
              {"shopify_app", "Shopify Apps", "🛍️", true},
              {"country", "Country", "🌍", true},
              {"business_model", "Business", "🏢", false},
              {"industry", "Industry", "🏭", false},
              {"revenue", "Revenue", "💰", false},
              {"employees", "Employees", "👥", false},
              {"language", "Language", "🗣️", true},
              {"freshness", "Freshness", "🕐", false}
            ] do %>
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
              <a href={~p"/app/export?" <> URI.encode_query(filter_params(@filters))}
                class="inline-flex items-center gap-2 h-9 px-4 bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg text-sm font-semibold shadow-lg shadow-emerald-500/20 transition">
                <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 10v6m0 0l-3-3m3 3l3-3m2 8H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" /></svg>
                Export CSV
              </a>
            </div>
          </div>
        </div>

        <%!-- Main content --%>
        <div class="flex gap-4 pb-6">
          <%!-- Table --%>
          <div class={"flex-1 min-w-0 transition-all duration-200 #{if @expanded, do: "max-w-[60%]"}"}>
            <div class="rounded-xl border border-white/[0.06] bg-[#0F1628] overflow-hidden">
              <div class="overflow-x-auto">
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
                        class={"group cursor-pointer transition-colors hover:bg-emerald-500/[0.04] #{if @expanded == row["domain"], do: "bg-emerald-500/[0.07] ring-1 ring-inset ring-emerald-500/20"}"}>
                        <td class="px-4 py-2.5 font-medium text-emerald-400 truncate"><%= row["domain"] %></td>
                        <td class="px-3 py-2.5 truncate text-gray-300"><%= row["http_title"] %></td>
                        <td class="px-3 py-2.5">
                          <div class="flex flex-wrap gap-1 overflow-hidden">
                            <%= for tech <- format_tech(row["http_tech"]) |> Enum.take(2) do %>
                              <span class="px-1.5 py-0.5 bg-emerald-500/[0.08] text-emerald-400/90 rounded text-[11px] font-medium truncate max-w-[80px]"><%= tech %></span>
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
                        <td class="px-3 py-2.5 truncate text-gray-300"><%= country_flag(row["bgp_asn_country"]) %> <%= row["bgp_asn_country"] %></td>
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
                      <div class="flex h-9 w-9 items-center justify-center rounded-lg bg-emerald-500/10 text-emerald-400 text-lg flex-shrink-0">🌐</div>
                      <div class="min-w-0 flex-1">
                        <h3 class="text-[15px] font-bold text-white truncate"><%= @detail["domain"] %></h3>
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
                <div class="overflow-y-auto max-h-[calc(100vh-180px)] p-5 space-y-4" style="scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.08) transparent;">
                  <%!-- Crawled / enriched timestamp --%>
                  <div class="flex items-center gap-2 text-[11px] text-gray-500 pb-1 border-b border-white/[0.04]">
                    <span>🕐</span>
                    <span>Crawled: <span class="text-gray-300"><%= format_datetime(@detail["enriched_at"]) %></span></span>
                  </div>

                  <%!-- Classification --%>
                  <div class="grid grid-cols-2 gap-2.5">
                    <.detail_card icon="🏢" label="Business Model" value={@detail["business_model"]} />
                    <.detail_card icon="🏭" label="Industry" value={@detail["industry"]} />
                    <.detail_card icon="💰" label="Revenue" value={@detail["estimated_revenue"]} />
                    <.detail_card icon="👥" label="Employees" value={@detail["estimated_employees"]} />
                    <.detail_card icon="🌍" label="Country" value={if @detail["bgp_asn_country"], do: "#{country_flag(@detail["bgp_asn_country"])} #{@detail["bgp_asn_country"]}"} />
                    <.detail_card icon="🗣️" label="Language" value={@detail["http_language"]} />
                  </div>

                  <%!-- Confidence scores --%>
                  <%= if has_value?(@detail["classification_confidence"]) || has_value?(@detail["revenue_confidence"]) do %>
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🎯" label="Class. Confidence" value={format_pct(@detail["classification_confidence"])} />
                      <.detail_card icon="📊" label="Rev. Confidence" value={format_pct(@detail["revenue_confidence"])} />
                    </div>
                  <% end %>

                  <%!-- Tech stack --%>
                  <.detail_section icon="🔧" label="Tech Stack">
                    <div class="flex flex-wrap gap-1.5">
                      <%= for tech <- format_tech(@detail["http_tech"]) do %>
                        <span class="px-2 py-1 bg-emerald-500/[0.08] text-emerald-400/90 rounded-md text-[11px] font-medium"><%= tech %></span>
                      <% end %>
                      <%= if format_tech(@detail["http_tech"]) == [] do %>
                        <span class="text-gray-600 text-xs">No data</span>
                      <% end %>
                    </div>
                  </.detail_section>

                  <%!-- Apps --%>
                  <%= if has_value?(@detail["http_apps"]) do %>
                    <.detail_section icon="📦" label="Apps">
                      <div class="flex flex-wrap gap-1.5">
                        <%= for app <- format_tech(@detail["http_apps"]) do %>
                          <span class="px-2 py-1 bg-blue-500/[0.08] text-blue-400/90 rounded-md text-[11px] font-medium"><%= app %></span>
                        <% end %>
                      </div>
                    </.detail_section>
                  <% end %>

                  <%!-- Revenue Evidence --%>
                  <%= if format_evidence(@detail["revenue_evidence"]) != [] do %>
                    <.detail_section icon="📊" label="Revenue Evidence">
                      <ul class="space-y-1.5">
                        <%= for item <- format_evidence(@detail["revenue_evidence"]) do %>
                          <li class="flex items-start gap-2 text-[12px] text-gray-300">
                            <span class="w-1 h-1 rounded-full bg-emerald-500/60 mt-1.5 flex-shrink-0"></span>
                            <span><%= item %></span>
                          </li>
                        <% end %>
                      </ul>
                    </.detail_section>
                  <% end %>

                  <%!-- HTTP info --%>
                  <.detail_section icon="🌐" label="HTTP">
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="⚡" label="Response Time" value={format_response_time(@detail["http_response_time"])} />
                      <.detail_card icon="📡" label="Status" value={@detail["http_status"]} />
                      <.detail_card icon="📄" label="Content Type" value={@detail["http_content_type"]} />
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
                    <%= if has_value?(@detail["http_pages"]) do %>
                      <div class="mt-2.5 bg-[#0B1020] rounded-lg p-3">
                        <div class="text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-1">📑 Pages</div>
                        <div class="flex flex-wrap gap-1.5">
                          <%= for page <- format_pipe_list(@detail["http_pages"]) |> Enum.take(10) do %>
                            <span class="px-2 py-0.5 bg-white/[0.04] text-gray-400 rounded text-[11px]"><%= page %></span>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </.detail_section>

                  <%!-- Emails --%>
                  <%= if has_value?(@detail["http_emails"]) do %>
                    <.detail_section icon="📧" label="Emails">
                      <div class="space-y-1">
                        <%= for email <- format_pipe_list(@detail["http_emails"]) do %>
                          <div class="text-[12px] text-blue-400"><%= email %></div>
                        <% end %>
                      </div>
                    </.detail_section>
                  <% end %>

                  <%!-- DNS --%>
                  <.detail_section icon="🔍" label="DNS">
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🅰️" label="A Record" value={@detail["dns_a"]} />
                      <.detail_card icon="6️⃣" label="AAAA Record" value={@detail["dns_aaaa"]} />
                      <.detail_card icon="📮" label="MX Record" value={@detail["dns_mx"]} />
                      <.detail_card icon="↪️" label="CNAME" value={@detail["dns_cname"]} />
                    </div>
                  </.detail_section>

                  <%!-- Network / BGP --%>
                  <.detail_section icon="📡" label="Network (BGP)">
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🔢" label="IP Address" value={@detail["bgp_ip"]} />
                      <.detail_card icon="#️⃣" label="ASN Number" value={@detail["bgp_asn_number"]} />
                      <.detail_card icon="🏢" label="ASN Org" value={@detail["bgp_asn_org"]} />
                      <.detail_card icon="🌐" label="ASN Prefix" value={@detail["bgp_asn_prefix"]} />
                    </div>
                  </.detail_section>

                  <%!-- RDAP / Domain registration --%>
                  <.detail_section icon="🏛️" label="Domain Registration (RDAP)">
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="📅" label="Created" value={format_date(@detail["rdap_domain_created_at"])} />
                      <.detail_card icon="⏳" label="Expires" value={format_date(@detail["rdap_domain_expires_at"])} />
                      <.detail_card icon="🔄" label="Updated" value={format_date(@detail["rdap_domain_updated_at"])} />
                      <.detail_card icon="🏛️" label="Registrar" value={@detail["rdap_registrar"]} />
                      <.detail_card icon="🆔" label="Registrar IANA" value={@detail["rdap_registrar_iana_id"]} />
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
                  </.detail_section>

                  <%!-- SSL / Certificate Transparency --%>
                  <.detail_section icon="🔒" label="SSL / Certificates">
                    <div class="grid grid-cols-2 gap-2.5">
                      <.detail_card icon="🔒" label="SSL Issuer" value={@detail["ctl_issuer"]} />
                      <.detail_card icon="🌐" label="TLD" value={@detail["ctl_tld"]} />
                      <.detail_card icon="🔢" label="Subdomains" value={@detail["ctl_subdomain_count"]} />
                    </div>
                  </.detail_section>

                  <%!-- Subdomain list --%>
                  <%= if format_subdomains(@detail["ctl_subdomains"]) != [] do %>
                    <.detail_section icon="🔗" label="Subdomain List">
                      <div class="flex flex-wrap gap-1.5">
                        <%= for sub <- format_subdomains(@detail["ctl_subdomains"]) |> Enum.take(30) do %>
                          <span class="px-2 py-1 bg-white/[0.04] text-gray-400 rounded-md text-[11px]"><%= sub %></span>
                        <% end %>
                        <%= if length(format_subdomains(@detail["ctl_subdomains"])) > 30 do %>
                          <span class="text-gray-600 text-[11px]">+<%= length(format_subdomains(@detail["ctl_subdomains"])) - 30 %> more</span>
                        <% end %>
                      </div>
                    </.detail_section>
                  <% end %>

                  <%!-- Rankings --%>
                  <.detail_section icon="📈" label="Rankings">
                    <div class="grid grid-cols-3 gap-2.5">
                      <.detail_card icon="📈" label="Tranco" value={format_rank(@detail["tranco_rank"])} />
                      <.detail_card icon="👑" label="Majestic" value={format_rank(@detail["majestic_rank"])} />
                      <.detail_card icon="🌐" label="Ref Subnets" value={@detail["majestic_ref_subnets"]} />
                    </div>
                  </.detail_section>

                  <%!-- Reputation flags --%>
                  <%= if any_flag?(@detail) do %>
                    <.detail_section icon="🛡️" label="Reputation">
                      <div class="flex flex-wrap gap-2">
                        <.flag_badge label="Malware" value={@detail["is_malware"]} />
                        <.flag_badge label="Phishing" value={@detail["is_phishing"]} />
                        <.flag_badge label="Disposable Email" value={@detail["is_disposable_email"]} />
                      </div>
                    </.detail_section>
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

      <%!-- Upgrade modal --%>
      <%= if @show_upgrade do %>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" phx-click="close_upgrade">
          <div class="bg-[#0F1628] border border-white/[0.08] rounded-2xl p-7 max-w-sm w-full mx-4 shadow-2xl" phx-click-away="close_upgrade">
            <h3 class="text-lg font-bold text-white mb-2">Upgrade to Pro</h3>
            <p class="text-gray-400 text-sm mb-6">Get 5,000 CSV exports/mo, 100 results/page, and full data access.</p>
            <div class="border border-emerald-500/20 rounded-xl p-5 bg-emerald-500/[0.03]">
              <h4 class="font-semibold text-emerald-400 text-sm">Pro</h4>
              <p class="text-3xl font-bold text-white mt-1">$49<span class="text-sm text-gray-500 font-normal">/mo</span></p>
              <ul class="text-sm text-gray-400 mt-3 space-y-1.5">
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> 5,000 CSV exports/mo</li>
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> 100 results per page</li>
                <li class="flex items-center gap-2"><span class="text-emerald-500">&#10003;</span> Full data access</li>
              </ul>
              <form action={~p"/subscription/checkout/pro/monthly"} method="post" class="mt-5">
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <button type="submit" class="w-full bg-emerald-600 hover:bg-emerald-500 text-white rounded-lg px-4 py-2.5 text-sm font-semibold shadow-lg shadow-emerald-500/25 transition">
                  Upgrade Now
                </button>
              </form>
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
      <span class={"inline-flex items-center gap-1 #{if @active, do: "text-emerald-400", else: "text-gray-500"}"}>
        <%= @label %>
        <%= if @summary do %>
          <span class="text-[9px] font-bold bg-emerald-500/20 text-emerald-400 rounded px-1 py-0.5 normal-case max-w-[60px] truncate" title={@summary}><%= @summary %></span>
        <% end %>
      </span>
      <%!-- Resize handle --%>
      <div class="col-resize-handle absolute right-0 top-0 bottom-0 w-1.5 cursor-col-resize bg-transparent hover:bg-emerald-500/30 transition-colors"></div>
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
            do: "bg-emerald-500/[0.08] border-emerald-500/30 text-emerald-400",
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
          <div class="max-h-56 overflow-y-auto" style="scrollbar-width: thin; scrollbar-color: rgba(255,255,255,0.08) transparent;">
            <%= for option <- @dropdown_options do %>
              <% checked = MapSet.member?(@selected, option) %>
              <div
                phx-click="select_option"
                phx-value-field={@field}
                phx-value-value={option}
                class={"flex items-center gap-2.5 w-full px-3 py-2 text-sm text-left transition cursor-pointer select-none " <>
                  if(checked, do: "bg-emerald-500/[0.06]", else: "hover:bg-white/[0.03]")}
              >
                <span class={"flex items-center justify-center w-4 h-4 rounded flex-shrink-0 border transition " <>
                  if(checked,
                    do: "bg-emerald-500 border-emerald-500",
                    else: "border-gray-600 bg-transparent"
                  )}>
                  <%= if checked do %>
                    <svg class="w-3 h-3 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="3"><path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" /></svg>
                  <% end %>
                </span>
                <span class={"truncate #{if checked, do: "text-emerald-400 font-medium", else: "text-gray-300"}"}><%= option %></span>
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

  defp detail_section(assigns) do
    ~H"""
    <div class="bg-[#0B1020]/50 rounded-lg p-3.5 border border-white/[0.03]">
      <div class="flex items-center gap-1.5 text-[10px] text-gray-600 uppercase tracking-wider font-semibold mb-2.5">
        <span><%= @icon %></span><%= @label %>
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

  defp plan_badge_class("pro"), do: "bg-emerald-500/15 text-emerald-400 ring-1 ring-emerald-500/20"
  defp plan_badge_class(_), do: "bg-gray-500/15 text-gray-400 ring-1 ring-gray-500/20"

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
end
