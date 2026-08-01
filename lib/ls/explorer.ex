defmodule LS.Explorer do
  @moduledoc "Builds and executes ClickHouse queries for the data explorer."

  alias LS.Clickhouse

  # Explorer queries scan the whole table (see list_sql/2), so they need more room
  # than LS.Clickhouse's default. The dashboard's Task.await must stay above this,
  # or it kills the query before the timeout can report it.
  @query_timeout 20_000
  @export_timeout 60_000

  # `domain` is appended to the ORDER BY as a tiebreaker: tranco_rank has huge NULL
  # ties, and without a deterministic order the same row can appear on two pages or
  # on none.
  @order_by "tranco_rank ASC NULLS LAST, domain ASC"

  # domains_current is a ReplacingMergeTree and we deliberately do not use FINAL
  # (too expensive at 82M rows), so a domain re-enriched since the last merge still
  # has its old row present. Those duplicates take up page slots: lightricks.com was
  # observed at the end of page 1 and again at the top of page 2.
  #
  # `LIMIT 1 BY domain` over the whole stream fixes it but costs 25x on the
  # unfiltered default view (0.16s -> 4.05s): with no WHERE, the plain top-25 can
  # early-terminate on a partial sort, while deduping forces a full pass over 82M
  # rows. So dedupe a bounded prefix instead — take offset+per_page+@dedupe_slack
  # rows (still a cheap top-N), dedupe those, then apply the offset to the deduped
  # result. Correct as long as the prefix holds fewer than @dedupe_slack duplicates;
  # the table currently runs ~0.03% duplicates across 5 merged parts, so a slack of
  # 100 over a prefix of a few hundred rows is a very wide margin.
  #
  #   unfiltered page 1   0.16s no dedupe / 4.05s full dedupe / 0.56s prefix dedupe
  #   US + $1M-$10M       1.17s no dedupe / 0.97s full dedupe / 1.54s prefix dedupe
  @dedupe "LIMIT 1 BY domain"
  @dedupe_slack 100

  @columns_raw ~w(
    domain http_title http_tech http_apps business_model industry
    estimated_revenue estimated_employees http_language enriched_at
    tranco_rank majestic_rank http_response_time
  )

  defp columns_sql do
    Enum.join(@columns_raw ++ ["inferred_country"], ", ")
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

  # Business-model and industry options are derived from the live data (distinct_by_count/2),
  # not a hardcoded list — the classifier's categories are the source of truth, so the dropdowns
  # can never offer a value that returns 0 rows (e.g. "Technology", which the classifier never emits).

  # domains_current is ORDER BY domain, so there is no index for these queries:
  # every filtered page is a full scan, and ORDER BY tranco_rank forces the whole
  # matching set to be materialised before the LIMIT applies. Selecting the wide
  # String columns (http_title, http_tech, http_apps) inside that scan meant
  # reading ~4.5GB to return 25 rows — 5-8s idle on the 3-core master, and past
  # the query timeout under load, which the dashboard showed as "Search
  # unavailable" after 10s.
  #
  # Two phases instead: rank on the narrow columns to pick 25 domains, then fetch
  # the wide ones by primary key. Measured against production (81M rows):
  #
  #   country=US + revenue $1M-$10M   5.06s / 4.51GB  ->  0.89s / 1.93GB
  #   tech=Klaviyo                    3.25s / 5.24GB  ->  1.49s / 2.98GB
  #   industry=Fintech, page 20       3.13s / 5.36GB  ->  0.90s / 2.05GB
  @doc "SQL for one page of results. Public so performance tests measure the real query."
  def list_sql(filters, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 25)
    page = Keyword.get(opts, :page, 1)
    offset = (page - 1) * per_page
    where = build_where(filters)

    """
    SELECT #{columns_sql()}
    FROM domains_current
    WHERE domain IN (
      SELECT domain FROM (
        SELECT domain
        FROM domains_current
        #{where}
        ORDER BY #{@order_by}
        LIMIT #{offset + per_page + @dedupe_slack}
      )
      #{@dedupe}
      LIMIT #{per_page}
      OFFSET #{offset}
    )
    ORDER BY #{@order_by}
    #{@dedupe}
    LIMIT #{per_page}
    """
  end

  def list(filters, opts \\ []) do
    case Clickhouse.query_raw(list_sql(filters, opts), @query_timeout) do
      {:ok, rows} -> {:ok, rows_to_maps(rows, column_names())}
      err -> err
    end
  end

  @doc "SQL for the total-row count. Public so performance tests measure the real query."
  def count_sql(filters), do: "SELECT count() FROM domains_current #{build_where(filters)}"

  def count(filters) do
    case Clickhouse.query_raw(count_sql(filters), @query_timeout) do
      {:ok, [[count]]} when is_integer(count) -> {:ok, count}
      {:ok, [[count]]} when is_binary(count) -> {:ok, String.to_integer(count)}
      _ -> {:ok, 0}
    end
  end

  def get_detail(domain) when is_binary(domain) do
    sql = """
    SELECT #{Enum.join(@detail_columns, ", ")}
    FROM domains_current
    WHERE domain = '#{Clickhouse.escape_public(domain)}'
    LIMIT 1
    """

    case Clickhouse.query_raw(sql) do
      {:ok, [row]} ->
        {:ok, row |> row_to_map(@detail_columns) |> Map.merge(depth_detail(domain))}

      {:ok, []} ->
        {:ok, nil}

      err ->
        err
    end
  end

  # Pipeline 2's contribution to the detail card: the 1:1 depth signals plus
  # the child rows (contacts, prices, jobs, catalogue). Absent for a business
  # that has not been deep-enriched yet, which is most of them — so every
  # caller must treat these keys as optional, and the card only draws a
  # section when its list is non-empty.
  #
  # One query per child table rather than a join: these are tiny keyed
  # lookups, and a five-way FINAL join on the master costs far more than five
  # point reads (a JOIN measures ~9x a single-table scan here).
  defp depth_detail(domain) do
    d = Clickhouse.escape_public(domain)

    %{
      "depth" => depth_summary(d),
      "contacts" => child_rows("SELECT email, source_page, seen_at FROM biz_contact FINAL WHERE domain = '#{d}' ORDER BY email LIMIT 50", ~w(email source_page seen_at)),
      "pricing" => child_rows("SELECT price, currency, seen_at FROM biz_pricing FINAL WHERE domain = '#{d}' ORDER BY price LIMIT 50", ~w(price currency seen_at)),
      "jobs" => child_rows("SELECT title, location, url, posted_at FROM biz_career FINAL WHERE domain = '#{d}' ORDER BY title LIMIT 100", ~w(title location url posted_at)),
      "products" => child_rows("SELECT title, price, vendor, product_type, available FROM biz_products FINAL WHERE domain = '#{d}' ORDER BY price DESC LIMIT 100", ~w(title price vendor product_type available)),
      "collections" => child_rows("SELECT title, products_count FROM biz_collections FINAL WHERE domain = '#{d}' ORDER BY products_count DESC LIMIT 50", ~w(title products_count))
    }
  end

  @depth_columns ~w(
    render_engine depth_enriched_at
    product_count price_min price_avg price_max new_products_30d oos_ratio
    discount_depth vendor_count catalog_age_days product_types
    job_count ats_platform job_departments job_locations
    seo_score seo_issues seo_word_count seo_alt_ratio
    perf_lcp_ms perf_cls perf_ttfb_ms
    about_text mission hq_location positions_overview
    pricing_points news_count last_funding_usd
  )

  defp depth_summary(escaped_domain) do
    sql = """
    SELECT #{Enum.join(@depth_columns, ", ")}
    FROM businesses FINAL
    WHERE domain = '#{escaped_domain}'
    LIMIT 1
    """

    case Clickhouse.query_raw(sql) do
      {:ok, [row]} -> row_to_map(row, @depth_columns)
      _ -> %{}
    end
  end

  defp child_rows(sql, columns) do
    case Clickhouse.query_raw(sql) do
      {:ok, rows} when is_list(rows) -> Enum.map(rows, &row_to_map(&1, columns))
      _ -> []
    end
  end

  # Depth columns worth carrying into a CSV. Deliberately not every child row:
  # a business with 400 products cannot be one CSV row, and exploding it into
  # 400 rows breaks every "one row per company" assumption a buyer has. The
  # 1:many data is therefore SUMMARISED here (counts, ranges, top values) and
  # the full lists stay in the app and the API.
  @export_depth_columns ~w(
    product_count price_min price_avg price_max new_products_30d vendor_count
    job_count ats_platform job_departments
    seo_score perf_lcp_ms
    hq_location mission
    pricing_points depth_enriched_at
  )

  # `businesses` carries tranco_rank too, so an unqualified ORDER BY is
  # ambiguous once the join is in play.
  defp qualified_order_by do
    @order_by
    |> String.replace("tranco_rank", "d.tranco_rank")
    |> String.replace(~r/(?<![\w.])domain\b/, "d.domain")
  end

  def export_rows(filters, limit) do
    where = build_where(filters)
    depth_select = Enum.map_join(@export_depth_columns, ", ", &"b.#{&1}")

    # Same two-phase shape as list_sql/2 — an export selects 40+ columns, so
    # scanning them across the whole match set is even worse than for one page.
    #
    # The LEFT JOIN onto `businesses` is what puts pipeline-2 depth in the
    # customer's file. It is a left join on purpose: a business we have not
    # deep-enriched yet still belongs in the export, with empty depth columns
    # rather than being silently dropped.
    sql = """
    SELECT #{Enum.map_join(@detail_columns, ", ", &"d.#{&1}")}, #{depth_select},
           c.emails AS enriched_emails
    FROM domains_current d
    LEFT JOIN (SELECT * FROM businesses FINAL) b ON d.domain = b.domain
    LEFT JOIN (
      SELECT domain, arrayStringConcat(groupArray(email), '|') AS emails
      FROM biz_contact FINAL GROUP BY domain
    ) c ON d.domain = c.domain
    WHERE d.domain IN (
      SELECT domain FROM (
        SELECT domain FROM domains_current
        #{where}
        ORDER BY #{@order_by}
        LIMIT #{limit + @dedupe_slack}
      )
      LIMIT #{limit}
    )
    ORDER BY #{qualified_order_by()}
    LIMIT #{limit}
    SETTINGS join_use_nulls = 1
    """

    columns = @detail_columns ++ @export_depth_columns ++ ["enriched_emails"]

    case Clickhouse.query_raw(sql, @export_timeout) do
      {:ok, rows} -> {:ok, {columns, rows}}
      err -> err
    end
  end

  @doc "Get distinct values for a column, optionally filtered by prefix. For typeahead filters."
  def distinct_values(column, prefix \\ "", limit \\ 50) when column in ~w(http_tech country http_language) do
    {col_expr, col_alias} = if column == "country" do
      {"inferred_country", "country"}
    else
      {column, column}
    end

    prefix_clause = if prefix != "", do: "AND lower(#{col_alias}) LIKE '%#{esc(String.downcase(prefix))}%'", else: ""

    sql = """
    SELECT DISTINCT #{col_expr} AS #{col_alias}
    FROM domains_current
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
    FROM domains_current
    WHERE http_tech != ''
    GROUP BY tech
    #{prefix_clause}
    ORDER BY count() DESC
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
    FROM domains_current
    WHERE http_apps != '' #{tech_clause}
    GROUP BY app
    #{prefix_clause}
    ORDER BY count() DESC
    LIMIT #{limit}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [v] -> v end)}
      _ -> {:ok, []}
    end
  end

  @doc "Distinct values of a low-cardinality column ordered by frequency (for dropdown options)."
  def distinct_by_count(column, limit \\ 300)
      when column in ~w(inferred_country http_language business_model industry) do
    # Collapse language region subtags (en-US / en-us -> en) so values match the curated list.
    expr = if column == "http_language", do: "splitByChar('-', lower(http_language))[1]", else: column

    sql = """
    SELECT #{expr} AS v
    FROM domains_current
    WHERE #{expr} != ''
    GROUP BY v
    ORDER BY count() DESC
    LIMIT #{limit}
    """

    case Clickhouse.query_raw(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [v] -> v end)}
      _ -> {:ok, []}
    end
  end

  @doc """
  The WHERE clause a set of filters compiles to ("" when nothing is filtered).

  Public so tests can assert on the SQL without a ClickHouse server: a filter
  that silently compiles to a clause matching nothing is indistinguishable from
  an empty database at the HTTP layer.
  """
  def where_sql(filters), do: build_where(filters)

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
    conditions = Enum.map(values, fn val -> "positionCaseInsensitive(http_tech, '#{esc(val)}') > 0" end)
    ["(" <> Enum.join(conditions, " AND ") <> ")"]
  end

  defp filter_clause({:shopify_app, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    conditions = Enum.map(values, fn val -> "positionCaseInsensitive(http_apps, '#{esc(val)}') > 0" end)
    ["(" <> Enum.join(conditions, " AND ") <> ")"]
  end

  defp filter_clause({:country, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["inferred_country = '#{esc(hd(values))}'"],
    else: ["inferred_country IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
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
        clauses ++ ["positionCaseInsensitive(http_tech, 'Shopify') > 0"]
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

  # ── Segment-specific filters (pipeline-2 depth data) ───────────────────────
  #
  # One table, two audiences. A commerce buyer filters on catalog size and
  # price; a SaaS buyer filters on pricing tiers and hiring. The UI shows only
  # the block that fits the chosen segment (see `segment_filters/1`), but the
  # SQL is the same flat scan either way — no joins, so latency stays flat.

  defp filter_clause({:min_products, v}), do: numeric_gte("product_count", v)
  defp filter_clause({:max_products, v}), do: numeric_lte("product_count", v)
  defp filter_clause({:min_price_avg, v}), do: numeric_gte("price_avg", v)
  defp filter_clause({:max_price_avg, v}), do: numeric_lte("price_avg", v)
  defp filter_clause({:min_new_products_30d, v}), do: numeric_gte("new_products_30d", v)
  defp filter_clause({:min_job_count, v}), do: numeric_gte("job_count", v)
  defp filter_clause({:min_seo_score, v}), do: numeric_gte("seo_score", v)

  defp filter_clause({:ats_platform, v}) when is_binary(v) and v != "",
    do: ["ats_platform = '#{esc(v)}'"]

  defp filter_clause({:has_pricing, "true"}), do: ["pricing_points > 0"]
  defp filter_clause({:has_email, "true"}), do: ["http_emails != ''"]
  defp filter_clause({:hiring, "true"}), do: ["job_count > 0"]


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
    # match on the primary subtag so "en" also matches stored "en-US", "en-us", etc.
    lang = "splitByChar('-', lower(http_language))[1]"

    if length(values) == 1,
      do: ["#{lang} = '#{esc(hd(values))}'"],
      else: ["#{lang} IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})"]
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

  defp numeric_gte(col, v), do: numeric(col, ">=", v)
  defp numeric_lte(col, v), do: numeric(col, "<=", v)

  # Filters come from query params, so never interpolate them as-is: parse to a
  # number or drop the clause entirely.
  defp numeric(col, op, v) do
    case v |> to_string() |> Float.parse() do
      {n, _} -> ["#{col} #{op} #{n}"]
      :error -> []
    end
  end

  @doc """
  Filter keys the UI should offer for a segment. The dashboard asks for these
  so a commerce user is never shown "min plans" and a SaaS user is never shown
  "out-of-stock ratio".
  """
  @spec segment_filters(String.t() | nil) :: [atom()]
  def segment_filters("Shopify"),
    do: [:min_products, :max_products, :min_price_avg, :max_price_avg,
         :min_new_products_30d, :has_email, :min_seo_score]

  def segment_filters(model) when model in ["SaaS", "Tool", "Marketplace", "Agency"],
    do: [:has_pricing, :min_price_avg, :hiring, :min_job_count, :ats_platform,
         :has_email, :min_seo_score]

  def segment_filters(_), do: [:has_email, :min_seo_score]

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
