defmodule LS.ApiData do
  @moduledoc """
  Read-only queries behind `/api/v1` and `/mcp` (data model v2, 2026-10-01).

  The JSON shape IS the product table: every field is a `businesses`
  column under its own name (`estimated_revenue`, `http_tech`,
  `hr_job_count`, ...), chosen per surface by `LS.Schema.Columns.api_columns/1`.
  The same names appear in the dashboard, the CSV export, the data
  dictionary on /developers and the OpenAPI schema, so a customer or an
  agent reads one vocabulary everywhere. Lists are JSON arrays, dates are
  ISO-8601 strings, absent numbers are null.

  Named columns only (never `SELECT *`), page sizes hard-capped server-side,
  every user-supplied value escaped. Contact emails are returned to the
  caller-facing layer, which decides per plan whether to expose them.
  """

  alias LS.Clickhouse
  alias LS.Schema.{Columns, Tables}

  @max_page 100

  @doc "Full company record for one domain, with its last 20 changes, or nil."
  def company(domain) when is_binary(domain) do
    d = domain |> String.trim() |> String.downcase() |> Clickhouse.escape_public()
    cols = Columns.api_columns(:company)

    sql = """
    SELECT #{Enum.map_join(cols, ", ", &select_expr/1)}
    FROM #{Tables.businesses()} FINAL
    WHERE domain = '#{d}'
    LIMIT 1
    """

    case Clickhouse.query_raw(sql) do
      {:ok, [row]} ->
        cols
        |> Enum.zip(row)
        |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
        |> Map.put(:changes, LS.Explorer.recent_changes(domain, 20))

      _ ->
        nil
    end
  end

  @doc """
  Filtered company search. `filters` accepts string keys straight from
  params: tech, app, dns_tech, email_provider, country (ISO-2),
  business_model, industry, revenue, employees, hiring ("true"), shopify
  ("true"), limit, offset. Returns `{:ok, rows, applied}` so the response
  can echo what was honoured (agents self-correct off it).
  """
  def search(filters) when is_map(filters) do
    conds =
      [
        has("http_tech", filters["tech"]),
        has("http_tech", filters["app"]),
        has("dns_tech", filters["dns_tech"]),
        eq("dns_email_provider", filters["email_provider"]),
        eq("estimated_country", upcase(filters["country"])),
        eq("estimated_business_model", filters["business_model"]),
        eq("estimated_industry", filters["industry"]),
        eq("estimated_revenue", filters["revenue"]),
        eq("estimated_employees", filters["employees"]),
        if(truthy?(filters["hiring"]), do: "hr_job_count > 0"),
        if(truthy?(filters["shopify"]), do: "is_shopify = 1"),
        "http_title != ''",
        "estimated_junk = ''"
      ]
      |> Enum.reject(&is_nil/1)

    limit = filters |> int("limit", 25) |> min(@max_page) |> max(1)
    offset = filters |> int("offset", 0) |> max(0) |> min(10_000)
    cols = Columns.api_columns(:search)

    sql = """
    SELECT #{Enum.map_join(cols, ", ", &select_expr/1)}, notEmpty(http_emails) AS has_contact
    FROM #{Tables.businesses()} FINAL
    WHERE #{Enum.join(conds, " AND ")}
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit} OFFSET #{offset}
    """

    case Clickhouse.query_raw(sql, 30_000) do
      {:ok, rows} ->
        keys = Enum.map(cols ++ ["has_contact"], &String.to_atom/1)
        rows = Enum.map(rows, fn r -> keys |> Enum.zip(r) |> Map.new() |> Map.update!(:has_contact, &(&1 in [1, "1", true])) end)
        {:ok, rows, %{limit: limit, offset: offset}}

      {:error, e} ->
        {:error, e}
    end
  end

  @doc "The filter names `search/1` honours, in the order the docs list them."
  def search_filters, do: ~w(tech app dns_tech email_provider country business_model industry revenue employees hiring shopify limit offset)

  @doc """
  Recorded changes, newest first. `filters`: field, change, value, domain,
  country, business_model, period (24h, 7d, 30d, 90d), limit, offset.
  """
  def changes(filters) when is_map(filters) do
    limit = filters |> int("limit", 50) |> min(@max_page) |> max(1)
    offset = filters |> int("offset", 0) |> max(0) |> min(10_000)
    page = div(offset, limit) + 1

    sig_filters = %{
      field: filters["field"] || "",
      change: filters["change"] || "",
      value: filters["value"] || "",
      domain_search: filters["domain"] || "",
      country: filters["country"] || "",
      business_model: filters["business_model"] || "",
      period: if(Map.has_key?(LS.Signals.periods(), filters["period"]), do: filters["period"], else: "7d")
    }

    case LS.Signals.list(sig_filters, per_page: limit, page: page) do
      {:ok, rows} ->
        rows =
          Enum.map(rows, fn r ->
            %{
              domain: r["domain"],
              field: r["field"],
              change: r["change"],
              value: r["value"],
              prev_value: r["prev_value"],
              changed_at: r["changed_at"],
              summary: LSWeb.ExplorerLive.Format.change_sentence(r["field"], r["change"], r["value"], r["prev_value"]),
              http_title: r["http_title"],
              estimated_country: r["estimated_country"],
              estimated_business_model: r["estimated_business_model"]
            }
          end)

        {:ok, rows, %{limit: limit, offset: offset, period: sig_filters.period}}

      {:error, e} ->
        {:error, e}
    end
  end

  def changes_filters, do: ~w(field change value domain country business_model period limit offset)

  @doc "Technology directory with usage counts (cached upstream)."
  def technologies do
    LS.LandingCache.tech_names()
    |> Enum.map(fn {name, count} ->
      {category, ecosystem} = LS.Tech.Catalog.info(name) || {:other, ""}
      %{name: name, companies: count, category: category, ecosystem: ecosystem}
    end)
  end

  @doc "Live dataset statistics from the 60s-refresh landing cache. Free."
  def stats do
    l = LS.LandingCache.get()

    %{
      # businesses_tracked is the PRODUCT table count (reachable, enriched
      # businesses), not domains-ever-seen. An agent will cite these numbers;
      # they must be the ones a customer can verify in the app.
      businesses_tracked: l.business_count,
      domains_scanned: l.total_domains,
      shopify_stores: l.store_count,
      technologies: max(l.tech_count, length(LS.LandingCache.tech_names())),
      domains_checked_past_hour: l.stores_last_hour,
      tracked_fields: LS.Signals.fields(),
      refreshed_at: l.refreshed_at
    }
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # DateTimes go out as ISO-8601 strings; everything else as itself.
  defp select_expr(col) do
    case Columns.get(col) do
      %{type: "DateTime"} -> "toString(#{col}) AS #{col}"
      %{type: "Nullable(DateTime)"} -> "toString(#{col}) AS #{col}"
      _ -> col
    end
  end

  defp has(_col, nil), do: nil
  defp has(_col, ""), do: nil
  defp has(col, v), do: "has(#{col}, '#{Clickhouse.escape_public(LS.Tech.Catalog.canonical(String.trim(v)))}')"

  defp eq(_col, nil), do: nil
  defp eq(_col, ""), do: nil
  defp eq(col, v), do: "#{col} = '#{Clickhouse.escape_public(v)}'"

  defp upcase(nil), do: nil
  defp upcase(v) when is_binary(v), do: String.upcase(v)

  defp truthy?(v), do: v in ["true", "1", true]

  defp int(filters, key, default) do
    case Integer.parse(to_string(filters[key] || default)) do
      {n, _} -> n
      _ -> default
    end
  end
end
