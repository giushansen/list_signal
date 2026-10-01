defmodule LS.Signals do
  @moduledoc """
  Queries behind the dashboard's Signals tab and the `/api/v1/changes`
  endpoint: the `changes_log` table, one row per change of one tracked
  column on one business (data model v2, 2026-10-01).

  A change is `{field, change, value, prev_value, changed_at}`: "Klaviyo
  added", "Yoast SEO removed", "revenue from $1M-$10M to $10M-$100M",
  "started hiring (12 roles)", "website down (503)". Which columns are
  tracked and by which rule is declared on the column spec
  (`LS.Schema.Columns.tracked/0`).

  Two query shapes, chosen by the filters:

    * no business filter: page the log first (its primary key is
      field, value, time, so "Klaviyo added last week" is a key range),
      then join `businesses` for the handful of domains on the page;
    * a country or business-model filter: join first on the window's
      domains, then page. Bounded by the period, which is why the UI
      never offers "all time" here.

  Exports share the explorer's monthly row quota: a change row costs one
  row, like a company row.
  """

  alias LS.Clickhouse
  alias LS.Schema.{Columns, Tables}

  @query_timeout 20_000
  @export_timeout 60_000

  @periods %{"24h" => 1, "7d" => 7, "30d" => 30, "90d" => 90}
  @changes ~w(added removed changed started stopped down back)

  @columns ~w(domain field change value prev_value changed_at http_title estimated_country estimated_business_model tranco_rank)

  @doc "Filter keys the tab accepts, all optional strings."
  def filter_keys, do: ~w(field change value domain_search country business_model period)a

  @doc "Tracked field names, for the dropdown."
  def fields, do: Columns.tracked() |> Enum.map(&elem(&1, 0))

  @doc "Change kinds, for the dropdown."
  def changes, do: @changes

  @doc "Periods offered, label -> days."
  def periods, do: @periods

  def default_filters,
    do: %{field: "", change: "", value: "", domain_search: "", country: "", business_model: "", period: "7d"}

  @doc "One page of changes, newest first, as maps keyed by column name."
  def list(filters, opts \\ []) do
    case Clickhouse.query_raw(list_sql(filters, opts), @query_timeout, max_execution_time: div(@query_timeout, 1000)) do
      {:ok, rows} -> {:ok, Enum.map(rows, &row_to_map/1)}
      err -> err
    end
  end

  @doc "How many changes match the filters (capped by the period)."
  def count(filters) do
    case Clickhouse.query_raw(count_sql(filters), @query_timeout, max_execution_time: div(@query_timeout, 1000)) do
      {:ok, [[n]]} -> {:ok, to_int(n)}
      {:ok, _} -> {:ok, 0}
      err -> err
    end
  end

  @doc "Rows for a CSV, newest first, at most `limit`."
  def export_rows(filters, limit) do
    case Clickhouse.query_raw(list_sql(filters, per_page: limit, page: 1), @export_timeout) do
      {:ok, rows} -> {:ok, {@columns ++ ["summary"], Enum.map(rows, &with_summary/1)}}
      err -> err
    end
  end

  def export_columns, do: @columns ++ ["summary"]

  @doc "The SQL for one page. Public so tests can assert on it without a server."
  def list_sql(filters, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 50)
    page = Keyword.get(opts, :page, 1)
    offset = (page - 1) * per_page
    log_where = log_where(filters)
    biz_where = biz_where(filters)
    changes = Tables.changes_log()
    businesses = Tables.businesses()
    biz_cols = "domain, http_title, estimated_country, estimated_business_model, tranco_rank"

    if biz_where == [] do
      """
      WITH page AS (
        SELECT domain, field, change, value, prev_value, changed_at
        FROM #{changes}
        WHERE #{Enum.join(log_where, " AND ")}
        ORDER BY changed_at DESC
        LIMIT #{per_page} OFFSET #{offset}
      )
      SELECT p.domain, p.field, p.change, p.value, p.prev_value, toString(p.changed_at),
             b.http_title, b.estimated_country, b.estimated_business_model, b.tranco_rank
      FROM page AS p
      LEFT JOIN (
        SELECT #{biz_cols} FROM #{businesses}
        WHERE domain IN (SELECT domain FROM page)
        ORDER BY compiled_at DESC
        LIMIT 1 BY domain
      ) AS b ON p.domain = b.domain
      ORDER BY p.changed_at DESC
      SETTINGS join_use_nulls = 0, max_threads = 2
      """
    else
      """
      SELECT c.domain, c.field, c.change, c.value, c.prev_value, toString(c.changed_at),
             b.http_title, b.estimated_country, b.estimated_business_model, b.tranco_rank
      FROM #{changes} AS c
      INNER JOIN (
        SELECT #{biz_cols} FROM #{businesses}
        WHERE domain IN (SELECT domain FROM #{changes} WHERE #{Enum.join(log_where, " AND ")})
          AND #{Enum.join(biz_where, " AND ")}
        ORDER BY compiled_at DESC
        LIMIT 1 BY domain
      ) AS b ON c.domain = b.domain
      WHERE #{Enum.join(log_where, " AND ")}
      ORDER BY c.changed_at DESC
      LIMIT #{per_page} OFFSET #{offset}
      SETTINGS join_use_nulls = 0, max_threads = 2
      """
    end
  end

  @doc false
  def count_sql(filters) do
    log_where = log_where(filters)
    biz_where = biz_where(filters)
    changes = Tables.changes_log()

    if biz_where == [] do
      "SELECT count() FROM #{changes} WHERE #{Enum.join(log_where, " AND ")}"
    else
      """
      SELECT count() FROM #{changes} AS c
      WHERE #{Enum.join(log_where, " AND ")}
        AND c.domain IN (
          SELECT domain FROM #{Tables.businesses()}
          WHERE domain IN (SELECT domain FROM #{changes} WHERE #{Enum.join(log_where, " AND ")})
            AND #{Enum.join(biz_where, " AND ")})
      """
    end
  end

  # ── where clauses ────────────────────────────────────────────────────────

  defp log_where(filters) do
    days = Map.get(@periods, get(filters, :period), 7)

    [
      "changed_at >= now() - INTERVAL #{days} DAY",
      in_list("field", get(filters, :field), fields()),
      in_list("change", get(filters, :change), @changes),
      value_clause(get(filters, :value)),
      domain_clause(get(filters, :domain_search))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp biz_where(filters) do
    [
      in_values("estimated_country", get(filters, :country), &String.upcase/1),
      in_values("estimated_business_model", get(filters, :business_model), & &1)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Only values from the allow-list reach the SQL: these come from query
  # params and `field`/`change` are the table's key columns.
  defp in_list(_col, "", _allowed), do: nil

  defp in_list(col, v, allowed) do
    vals = v |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.filter(&(&1 in allowed))
    if vals == [], do: "1 = 0", else: "#{col} IN (#{Enum.map_join(vals, ", ", &"'#{&1}'")})"
  end

  defp in_values(_col, "", _f), do: nil

  defp in_values(col, v, f) do
    vals = v |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.map(f)
    "#{col} IN (#{Enum.map_join(vals, ", ", &"'#{esc(&1)}'")})"
  end

  defp value_clause(""), do: nil
  defp value_clause(v), do: "value = '#{esc(v)}'"

  defp domain_clause(""), do: nil
  defp domain_clause(v), do: "domain LIKE '%#{esc(String.downcase(v))}%'"

  defp get(filters, key), do: to_string(Map.get(filters, key) || Map.get(filters, to_string(key)) || "")

  defp esc(s), do: Clickhouse.escape_public(s)

  # ── rows ─────────────────────────────────────────────────────────────────

  defp row_to_map(row), do: @columns |> Enum.zip(row) |> Map.new()

  defp with_summary(row) do
    m = row_to_map(row)
    row ++ [LSWeb.ExplorerLive.Format.change_sentence(m["field"], m["change"], m["value"], m["prev_value"])]
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> v
      :error -> 0
    end
  end

  defp to_int(_), do: 0
end
