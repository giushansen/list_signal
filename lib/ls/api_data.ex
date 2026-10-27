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
        |> with_contacts(d)

      _ ->
        nil
    end
  end

  # Who is behind the address (2026-10-26): each published email with its
  # kind and the page it was found on, the naming pattern the named ones
  # imply, and the people found on the site. All derived at read time from
  # the row and two keyed child reads; nothing new is stored on the row.
  defp with_contacts(record, d) do
    emails = List.wrap(record[:http_emails])
    sources = contact_sources(d)

    checks = email_checks(d)

    classified =
      Enum.map(emails, fn e ->
        base = %{email: e, kind: LS.HTTP.EmailClass.classify(e, d) |> Atom.to_string(), source_page: Map.get(sources, e, "homepage")}
        Map.merge(base, Map.get(checks, e, %{score: nil, verdict: "unscored", evidence: [], checked_at: nil}))
      end)

    pattern =
      case LS.HTTP.EmailClass.email_pattern(emails) do
        {shape, n} -> %{pattern: shape, support: n}
        nil -> nil
      end

    record
    |> Map.put(:email_details, classified)
    |> Map.put(:email_pattern, pattern)
    |> Map.put(:people, people(d))
  end

  # Score, verdict and evidence per address (LS.Email.Score, 2026-10-27).
  defp email_checks(d) do
    sql = "SELECT email, argMax(score, checked_at), argMax(verdict, checked_at), argMax(evidence, checked_at), toString(max(checked_at)) FROM #{Tables.email_checks()} WHERE domain = '#{d}' GROUP BY email LIMIT 40"

    case Clickhouse.query_raw(sql, 5_000) do
      {:ok, rows} -> Map.new(rows, fn [e, s, v, ev, at] -> {e, %{score: to_int(s), verdict: v, evidence: ev, checked_at: at}} end)
      _ -> %{}
    end
  end

  defp contact_sources(d) do
    sql = "SELECT email, argMax(source_page, seen_at) FROM #{Tables.http_contacts()} WHERE domain = '#{d}' GROUP BY email LIMIT 40"

    case Clickhouse.query_raw(sql, 5_000) do
      {:ok, rows} -> Map.new(rows, fn [e, p] -> {e, p} end)
      _ -> %{}
    end
  end

  defp people(d) do
    sql = "SELECT name, argMax(title, seen_at), argMax(email, seen_at), argMax(source_page, seen_at), toString(max(seen_at)) FROM #{Tables.http_people()} WHERE domain = '#{d}' GROUP BY name ORDER BY max(seen_at) DESC LIMIT 20"

    case Clickhouse.query_raw(sql, 5_000) do
      {:ok, rows} -> Enum.map(rows, fn [n, t, e, s, at] -> %{name: n, title: t, email: e, source_page: s, seen_at: at} end)
      _ -> []
    end
  end

  @doc """
  Filtered company search. `filters` accepts every `LS.Query` name as a
  string key straight from params (REST) or from a tool's arguments
  (MCP), plus `sort`, `limit`, `offset` and `total` ("true" adds the
  count of everything that matches, the same number the dashboard shows).
  `opts[:max_page]` is the plan's rows-a-page cap. Returns
  `{:ok, rows, applied}`: `applied` echoes the filters honoured, the
  names ignored and the paging, so an agent self-corrects off it.
  """
  def search(filters, opts \\ []) when is_map(filters) do
    max_page = Keyword.get(opts, :max_page, @max_page)
    conds = conditions(filters)
    limit = filters |> int("limit", min(25, max_page)) |> min(max_page) |> max(1)
    offset = filters |> int("offset", 0) |> max(0) |> min(10_000)
    sort = sort_key(filters["sort"])
    cols = Columns.api_columns(:search)
    where = Enum.join(conds, " AND ")

    sql = """
    SELECT #{Enum.map_join(cols, ", ", &select_expr/1)}, notEmpty(http_emails) AS has_contact
    FROM #{Tables.businesses()} FINAL
    WHERE #{where}
    ORDER BY #{order_sql(sort)}
    LIMIT #{limit} OFFSET #{offset}
    """

    with {:ok, rows} <- Clickhouse.query_raw(sql, 30_000),
         {:ok, total} <- maybe_total(filters, where) do
      keys = Enum.map(cols ++ ["has_contact"], &String.to_atom/1)
      rows = Enum.map(rows, fn r -> keys |> Enum.zip(r) |> Map.new() |> Map.update!(:has_contact, &(&1 in [1, "1", true])) end)
      {:ok, rows, Map.merge(echo(filters), %{limit: limit, offset: offset, sort: sort, total: total})}
    end
  end

  defp maybe_total(filters, where) do
    if truthy?(filters["total"]), do: count_where(where, "SETTINGS max_threads = 2, max_execution_time = 10"), else: {:ok, nil}
  end

  # What was honoured and what was not, by its public name.
  defp echo(filters) do
    {parsed, ignored} = LS.Query.parse(filters)
    %{filters: Map.new(LS.Query.to_params(parsed)), ignored: ignored}
  end

  @doc """
  How many companies match, and nothing else (2026-10-27). Free on every
  plan: an agent sizes a segment before it pulls it, which is what keeps
  it inside its rows. Same filters, same base scope, same number as the
  dashboard's result count. Counts skip FINAL (duplicates from unmerged
  parts run about 0.03%) and say so.
  """
  @spec count(map()) :: {:ok, map()} | {:error, term()}
  def count(filters) when is_map(filters) do
    where = filters |> conditions() |> Enum.join(" AND ")

    with {:ok, total} <- count_where(where, "SETTINGS max_threads = 2, max_execution_time = 10") do
      {:ok, Map.merge(echo(filters), %{total: total, total_note: "approximate: duplicates from unmerged parts run about 0.03%"})}
    end
  end

  @doc "The names `search/1`, `count/1` and `query/1` honour: the grammar, then paging."
  def search_filters, do: LS.Query.names() ++ ~w(total sort limit offset)

  # The keys the API renders itself, in the exact text it has promised
  # since v2 (pinned by test/ls/api_data_query_test.exs): the single-name
  # `has()` for a technology, the band equalities on the estimated columns,
  # the IN lists with a space after the comma. Everything else is built by
  # LS.Explorer so a name means one thing on every surface.
  @own_keys ~w(tech dns_tech dns_email_provider country business_model industry revenue employees realness)a

  @doc """
  The WHERE clauses `search/1`, `count/1` and `query/1` share. Every value
  is parsed by `LS.Query` (number, date, fixed list) or escaped; nothing
  from the caller reaches the SQL as written. The base scope (a fetched
  homepage, no junk verdict) closes the list.
  """
  @spec conditions(map()) :: [String.t()]
  def conditions(filters) when is_map(filters) do
    filters = Map.new(filters, fn {k, v} -> {to_string(k), v} end)
    {parsed, _ignored} = LS.Query.parse(filters)

    own = [
      tech_clause("http_tech", filters["tech"]),
      tech_clause("http_tech", filters["app"]),
      tech_clause("http_tech", filters["shopify_app"]),
      tech_clause("dns_tech", filters["dns_tech"]),
      list_or_eq("dns_email_provider", filters["email_provider"] || filters["dns_email_provider"]),
      in_list("estimated_country", filters["country"] |> upcase() |> csv()),
      model_clause(filters["business_model"]),
      list_or_eq("estimated_industry", filters["industry"]),
      in_list("estimated_revenue", csv(filters["revenue"])),
      in_list("estimated_employees", csv(filters["employees"])),
      gte("estimated_realness", filters["min_realness"] || filters["realness"])
    ]

    shared = parsed |> Map.drop(@own_keys) |> LS.Explorer.clauses()

    (own ++ shared ++ LS.Explorer.base_clauses(parsed))
    |> Enum.reject(&is_nil/1)
  end

  # One name keeps the promised `has(col, 'Name')`; a list is the
  # explorer's hasAll, the same meaning as the dashboard's tech filter.
  defp tech_clause(col, v) do
    case csv(v) do
      nil -> nil
      [] -> nil
      [one] -> has(col, one)
      many -> hd(LS.Explorer.clauses([{if(col == "dns_tech", do: :dns_tech, else: :tech), Enum.join(many, ",")}]))
    end
  end

  defp list_or_eq(col, v) do
    case csv(v) do
      nil -> nil
      [one] -> eq(col, one)
      many -> in_list(col, many)
    end
  end

  # "Shopify" is a platform, not a classifier label: it reads the stored
  # flag, as the dashboard does, and ORs with the real models.
  defp model_clause(v) do
    case csv(v) do
      nil ->
        nil

      vals ->
        {shopify, models} = Enum.split_with(vals, &(&1 == "Shopify"))

        parts =
          [in_list("estimated_business_model", if(models == [], do: nil, else: models)), if(shopify != [], do: "is_shopify = 1")]
          |> Enum.reject(&is_nil/1)

        case parts do
          [] -> nil
          [one] -> one
          many -> "(" <> Enum.join(many, " OR ") <> ")"
        end
    end
  end

  @sorts %{
    "relevance" => "#{LS.Explorer.target_score_sql()} DESC, http_last_checked_at DESC, domain ASC",
    "tranco" => "tranco_rank ASC NULLS LAST, domain ASC",
    "first_seen" => "ctl_first_seen_at DESC, domain ASC",
    "last_checked" => "http_last_checked_at DESC, domain ASC",
    "products" => "shop_product_count DESC NULLS LAST, domain ASC",
    "jobs" => "hr_job_count DESC NULLS LAST, domain ASC"
  }

  @doc "The sort keys `search/1` and `query/1` accept."
  def sort_keys, do: Map.keys(@sorts) |> Enum.sort()

  # The default is the explorer's target ranking (2026-10-23), not traffic:
  # sorted by Tranco the top of any model is adtech platforms and SaaS, and
  # the small businesses the product is for come last (2026-10-26 review:
  # 2 real agencies in the top 25 for business_model=Agency).
  defp sort_key(v) when is_binary(v), do: if(Map.has_key?(@sorts, v), do: v, else: "relevance")
  defp sort_key(_), do: "relevance"
  defp order_sql(key), do: Map.fetch!(@sorts, key)

  @group_by ~w(estimated_business_model estimated_country estimated_revenue estimated_employees estimated_industry dns_email_provider ctl_tld)
  @query_max 500

  @doc "The fields `group_by` accepts."
  def group_by_fields, do: @group_by

  @doc """
  One bounded read over the product table for analysis (2026-10-26): the
  same filters as `search/1`, a `sort`, a `fields` list drawn from the
  search columns, `group_by` with counts, and a total count. Row cap
  `opts[:max_rows]` (#{@query_max} by default, the plan's rows a page on
  Free and Starter), ten seconds of execution, two threads. `limit=0`
  returns the total and the groups only, and costs no rows. Counts skip
  FINAL (duplicates run about 0.03%) and say so.

  Returns `{:ok, %{rows, total, groups, applied}}`.
  """
  @spec query(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def query(filters, opts \\ []) when is_map(filters) do
    max_rows = Keyword.get(opts, :max_rows, @query_max)
    conds = conditions(filters)
    where = Enum.join(conds, " AND ")
    limit = filters |> int("limit", min(100, max_rows)) |> min(max_rows) |> max(0)
    offset = filters |> int("offset", 0) |> max(0) |> min(50_000)
    sort = sort_key(filters["sort"])
    settings = "SETTINGS max_threads = 2, max_execution_time = 10"
    allowed = Columns.api_columns(:search)

    cols =
      case filters["fields"] do
        list when is_list(list) -> list |> Enum.map(&to_string/1) |> Enum.filter(&(&1 in allowed)) |> Enum.uniq()
        s when is_binary(s) -> s |> csv() |> Enum.filter(&(&1 in allowed)) |> Enum.uniq()
        _ -> ~w(domain estimated_business_model estimated_country estimated_revenue estimated_employees http_tech)
      end

    cols = if cols == [], do: ["domain"], else: Enum.uniq(["domain" | cols])

    group_by =
      case filters["group_by"] do
        g when is_binary(g) and g != "" -> if(g in @group_by, do: g, else: :invalid)
        _ -> nil
      end

    with {:ok, total} <- count_where(where, settings),
         {:ok, groups} <- groups(group_by, where, settings),
         {:ok, rows} <- rows(cols, where, sort, limit, offset, settings) do
      {:ok,
       %{
         rows: rows,
         total: total,
         total_note: "approximate: duplicates from unmerged parts run about 0.03%",
         groups: groups,
         applied:
           Map.merge(echo(filters), %{
             limit: limit,
             offset: offset,
             sort: sort,
             fields: cols,
             group_by: if(group_by == :invalid, do: nil, else: group_by),
             group_by_accepted: @group_by,
             filters_accepted: search_filters(),
             sort_accepted: sort_keys()
           })
       }}
    end
  end

  defp count_where(where, settings) do
    case Clickhouse.query_raw("SELECT count() FROM #{Tables.businesses()} WHERE #{where} #{settings}", 15_000) do
      {:ok, [[n]]} -> {:ok, to_int(n)}
      {:error, e} -> {:error, e}
      _ -> {:ok, 0}
    end
  end

  defp groups(nil, _where, _settings), do: {:ok, nil}
  defp groups(:invalid, _where, _settings), do: {:ok, nil}

  defp groups(col, where, settings) do
    sql = "SELECT #{col}, count() AS n FROM #{Tables.businesses()} WHERE #{where} GROUP BY #{col} ORDER BY n DESC LIMIT 50 #{settings}"

    case Clickhouse.query_raw(sql, 15_000) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [v, n] -> %{value: v, count: to_int(n)} end)}
      {:error, e} -> {:error, e}
    end
  end

  defp rows(_cols, _where, _sort, 0, _offset, _settings), do: {:ok, []}

  defp rows(cols, where, sort, limit, offset, settings) do
    sql = """
    SELECT #{Enum.map_join(cols, ", ", &select_expr/1)}
    FROM #{Tables.businesses()} FINAL
    WHERE #{where}
    ORDER BY #{order_sql(sort)}
    LIMIT #{limit} OFFSET #{offset}
    #{settings}
    """

    case Clickhouse.query_raw(sql, 15_000) do
      {:ok, rows} ->
        keys = Enum.map(cols, &String.to_atom/1)
        {:ok, Enum.map(rows, fn r -> keys |> Enum.zip(r) |> Map.new() end)}

      {:error, e} ->
        {:error, e}
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: (case Integer.parse(n) do {i, _} -> i; _ -> 0 end)
  defp to_int(_), do: 0

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

  # A numeric floor, parsed so nothing but a number reaches the SQL.
  defp gte(_col, nil), do: nil
  defp gte(_col, ""), do: nil
  defp gte(col, v) when is_number(v) and v >= 0 and v <= 1, do: "#{col} >= #{v}"

  defp gte(col, v) when is_binary(v) do
    case Float.parse(String.trim_trailing(v, "+")) do
      {f, _} when f >= 0 and f <= 1 -> "#{col} >= #{f}"
      _ -> nil
    end
  end

  defp gte(_col, _), do: nil

  defp eq(_col, nil), do: nil
  defp eq(_col, ""), do: nil
  defp eq(col, v), do: "#{col} = '#{Clickhouse.escape_public(v)}'"

  defp upcase(nil), do: nil
  defp upcase(v) when is_binary(v), do: String.upcase(v)
  defp upcase(v) when is_list(v), do: Enum.map(v, &upcase(to_string(&1)))
  defp upcase(v), do: v

  # "US,FR" or ["US", "FR"] -> ["US", "FR"]; nil or "" -> nil.
  defp csv(nil), do: nil
  defp csv(""), do: nil
  defp csv(list) when is_list(list), do: list |> Enum.map(&to_string/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp csv(s) when is_binary(s), do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  defp csv(_), do: nil

  defp in_list(_col, nil), do: nil
  defp in_list(_col, []), do: nil
  defp in_list(col, [v]), do: eq(col, v)
  defp in_list(col, vals), do: "#{col} IN (#{Enum.map_join(vals, ", ", &"'#{Clickhouse.escape_public(&1)}'")})"

  defp truthy?(v), do: v in ["true", "1", true]

  defp int(filters, key, default) do
    case Integer.parse(to_string(filters[key] || default)) do
      {n, _} -> n
      _ -> default
    end
  end
end
