defmodule LS.Explorer do
  @moduledoc "Builds and executes ClickHouse queries for the data explorer."

  alias LS.Clickhouse

  @columns_raw ~w(
    domain http_title http_tech http_apps business_model industry
    estimated_revenue estimated_employees http_language enriched_at
    tranco_rank majestic_rank http_response_time
  )

  # Country is computed via expression for backward compat with existing data
  @country_expr LS.Clickhouse.country_expr()

  defp columns_sql do
    (@columns_raw ++ ["#{@country_expr} AS inferred_country"]) |> Enum.join(", ")
  end

  defp column_names, do: @columns_raw ++ ["inferred_country"]

  @detail_columns ~w(
    domain http_title http_tech http_apps http_status http_response_time
    http_language http_emails http_content_type http_meta_description
    http_h1 http_schema_type http_og_type http_pages
    bgp_ip bgp_asn_number bgp_asn_org bgp_asn_country bgp_asn_prefix
    dns_a dns_aaaa dns_mx dns_txt dns_cname
    rdap_registrar rdap_registrar_iana_id rdap_nameservers
    rdap_domain_created_at rdap_domain_expires_at rdap_domain_updated_at rdap_status
    ctl_tld ctl_issuer ctl_subdomains ctl_subdomain_count
    tranco_rank majestic_rank majestic_ref_subnets
    business_model industry classification_confidence
    estimated_revenue estimated_employees revenue_confidence revenue_evidence
    is_malware is_phishing is_disposable_email
    enriched_at
  )

  @business_models ~w(
    Ecommerce Shopify SaaS Tool Marketplace Agency Portfolio Blog Media
    Community Government Education Nonprofit Other
  )

  @industries ~w(
    Fashion Beauty Health Food Electronics Home Sports Automotive
    Pets Travel Education Entertainment Finance Technology Arts
    Agriculture Energy Legal Real\ Estate Telecom Other
  )

  def business_models, do: @business_models
  def industries, do: @industries

  def list(filters, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 25)
    page = Keyword.get(opts, :page, 1)
    offset = (page - 1) * per_page

    where = build_where(filters)

    sql = """
    SELECT #{columns_sql()}
    FROM domains_current FINAL
    #{where}
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{per_page}
    OFFSET #{offset}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, rows_to_maps(rows, column_names())}
      err -> err
    end
  end

  def count(filters) do
    where = build_where(filters)

    sql = "SELECT count() FROM domains_current FINAL #{where}"

    case Clickhouse.query_raw(sql) do
      {:ok, [[count]]} when is_integer(count) -> {:ok, count}
      {:ok, [[count]]} when is_binary(count) -> {:ok, String.to_integer(count)}
      _ -> {:ok, 0}
    end
  end

  def get_detail(domain) when is_binary(domain) do
    sql = """
    SELECT #{Enum.join(@detail_columns, ", ")}
    FROM domains_current FINAL
    WHERE domain = '#{Clickhouse.escape_public(domain)}'
    LIMIT 1
    """

    case Clickhouse.query_raw(sql) do
      {:ok, [row]} -> {:ok, row_to_map(row, @detail_columns)}
      {:ok, []} -> {:ok, nil}
      err -> err
    end
  end

  def export_rows(filters, limit) do
    where = build_where(filters)

    sql = """
    SELECT #{Enum.join(@detail_columns, ", ")}
    FROM domains_current FINAL
    #{where}
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, {@detail_columns, rows}}
      err -> err
    end
  end

  @doc "Get distinct values for a column, optionally filtered by prefix. For typeahead filters."
  def distinct_values(column, prefix \\ "", limit \\ 50) when column in ~w(http_tech country http_language) do
    {col_expr, col_alias} = if column == "country" do
      {"#{@country_expr}", "country"}
    else
      {column, column}
    end

    prefix_clause = if prefix != "", do: "AND lower(#{col_alias}) LIKE '%#{esc(String.downcase(prefix))}%'", else: ""

    sql = """
    SELECT DISTINCT #{col_expr} AS #{col_alias}
    FROM domains_current FINAL
    WHERE #{col_alias} != '' #{prefix_clause}
    ORDER BY #{col_alias} ASC
    LIMIT #{limit}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [v] -> v end)}
      _ -> {:ok, []}
    end
  end

  @doc "Get distinct tech values (split by pipe separator)."
  def distinct_techs(prefix \\ "", limit \\ 50) do
    prefix_clause = if prefix != "", do: "HAVING lower(tech) LIKE '%#{esc(String.downcase(prefix))}%'", else: ""

    sql = """
    SELECT arrayJoin(splitByChar('|', http_tech)) AS tech
    FROM domains_current FINAL
    WHERE http_tech != ''
    GROUP BY tech
    #{prefix_clause}
    ORDER BY tech ASC
    LIMIT #{limit}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [v] -> v end)}
      _ -> {:ok, []}
    end
  end

  @doc "Get distinct app values (split by pipe separator)."
  def distinct_apps(prefix \\ "", limit \\ 50, opts \\ []) do
    prefix_clause = if prefix != "", do: "HAVING lower(app) LIKE '%#{esc(String.downcase(prefix))}%'", else: ""
    tech_clause = if opts[:shopify_only], do: "AND lower(http_tech) LIKE '%shopify%'", else: ""

    sql = """
    SELECT arrayJoin(splitByChar('|', http_apps)) AS app
    FROM domains_current FINAL
    WHERE http_apps != '' #{tech_clause}
    GROUP BY app
    #{prefix_clause}
    ORDER BY app ASC
    LIMIT #{limit}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [v] -> v end)}
      _ -> {:ok, []}
    end
  end

  defp build_where(filters) do
    clauses =
      filters
      |> Enum.flat_map(&filter_clause/1)
      |> Enum.reject(&is_nil/1)

    case clauses do
      [] -> ""
      parts -> "WHERE " <> Enum.join(parts, " AND ")
    end
  end

  # Multi-value filter support: "US,GB,FR" → IN ('US','GB','FR')
  defp filter_clause({:tech, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    conditions = Enum.map(values, fn val -> "lower(http_tech) LIKE '%#{esc(String.downcase(val))}%'" end)
    ["(" <> Enum.join(conditions, " AND ") <> ")"]
  end

  defp filter_clause({:shopify_app, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    conditions = Enum.map(values, fn val -> "lower(http_apps) LIKE '%#{esc(String.downcase(val))}%'" end)
    ["(" <> Enum.join(conditions, " AND ") <> ")"]
  end

  defp filter_clause({:country, v}) when is_binary(v) and v != "" do
    ce = @country_expr
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["#{ce} = '#{esc(hd(values))}'"],
    else: ["#{ce} IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
  end

  defp filter_clause({:business_model, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    # "Shopify" is a platform detected via http_tech, not a business_model DB value
    {shopify, regular} = Enum.split_with(values, &(&1 == "Shopify"))

    clauses = []

    clauses =
      case regular do
        [] -> clauses
        [single] -> clauses ++ ["business_model = '#{esc(single)}'"]
        many -> clauses ++ ["business_model IN (#{Enum.map_join(many, ",", &"'#{esc(&1)}'")})" ]
      end

    clauses =
      if shopify != [] do
        clauses ++ ["lower(http_tech) LIKE '%shopify%'"]
      else
        clauses
      end

    case clauses do
      [] -> []
      [single] -> [single]
      multiple -> ["(" <> Enum.join(multiple, " OR ") <> ")"]
    end
  end

  defp filter_clause({:industry, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["industry = '#{esc(hd(values))}'"],
    else: ["industry IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
  end

  defp filter_clause({:revenue, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["estimated_revenue = '#{esc(hd(values))}'"],
    else: ["estimated_revenue IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
  end

  defp filter_clause({:employees, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["estimated_employees = '#{esc(hd(values))}'"],
    else: ["estimated_employees IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
  end

  defp filter_clause({:language, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["http_language = '#{esc(hd(values))}'"],
    else: ["http_language IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
  end

  defp filter_clause({:domain_search, v}) when is_binary(v) and v != "" do
    ["domain LIKE '%#{esc(String.downcase(v))}%'"]
  end

  defp filter_clause({:freshness, "24h"}) do
    ["enriched_at >= now() - INTERVAL 1 DAY"]
  end

  defp filter_clause({:freshness, "7d"}) do
    ["enriched_at >= now() - INTERVAL 7 DAY"]
  end

  defp filter_clause({:freshness, "30d"}) do
    ["enriched_at >= now() - INTERVAL 30 DAY"]
  end

  defp filter_clause(_), do: []

  defp esc(str), do: Clickhouse.escape_public(str)

  defp rows_to_maps(rows, columns) do
    Enum.map(rows, &row_to_map(&1, columns))
  end

  defp row_to_map(row, columns) do
    columns
    |> Enum.zip(row)
    |> Map.new(fn {k, v} -> {k, v} end)
  end
end
