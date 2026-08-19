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

  # `as_of AS enriched_at` keeps the alias the templates already use while
  # reading the column `businesses` actually has (the compactor's "newest
  # data we hold for this domain"). Depth columns ride along so the results
  # table can show and sort on what pipeline 2 found.
  @columns_raw [
    "domain", "http_title", "http_tech", "http_apps", "business_model", "industry",
    "estimated_revenue", "estimated_employees", "http_language", "as_of AS enriched_at",
    "verified_revenue", "verified_revenue_source", "verified_employees", "verified_employees_source",
    "tranco_rank", "majestic_rank", "http_response_time",
    "product_count", "price_avg", "job_count", "seo_score", "pricing_points",
    "depth_enriched_at"
  ]

  # The SELECT carries "as_of AS enriched_at"; the map keys must be the alias.
  @column_names ~w(
    domain http_title http_tech http_apps business_model industry
    estimated_revenue estimated_employees http_language enriched_at
    verified_revenue verified_revenue_source verified_employees verified_employees_source
    tranco_rank majestic_rank http_response_time
    product_count price_avg job_count seo_score pricing_points
    depth_enriched_at
  )

  defp columns_sql do
    Enum.join(@columns_raw ++ ["inferred_country"], ", ")
  end

  defp column_names, do: @column_names ++ ["inferred_country"]

  # Revenue/employees filters match what the reader SEES: the verified value
  # when pipeline 3 has one, else the estimate (same bracket vocabulary — the
  # data-contract suite checks that). Filtering on estimated_* alone would hide
  # a company whose verified 10-K revenue moved it out of the estimated bracket.
  @shown_revenue "if(verified_revenue != '', verified_revenue, estimated_revenue)"
  @shown_employees "if(verified_employees != '', verified_employees, estimated_employees)"

  @doc false
  def shown_revenue_sql, do: @shown_revenue
  @doc false
  def shown_employees_sql, do: @shown_employees


  # NOTE: no is_malware/is_phishing here. `businesses` excludes flagged domains
  # by construction (the compactor's HAVING drops them), so the columns were
  # always empty and migration 003 removed them. The card's Reputation section
  # no longer renders, which is correct: a flagged domain never reaches this
  # table at all.
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
    verified_revenue verified_revenue_source verified_employees verified_employees_source mission_summary
    is_disposable_email
    as_of last_verified_at crawlable dns_alive last_http_status last_http_blocked
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
    order = order_clause(Keyword.get(opts, :sort), Keyword.get(opts, :dir))

    """
    SELECT #{columns_sql()}
    FROM businesses FINAL
    WHERE domain IN (
      SELECT domain FROM (
        SELECT domain
        FROM businesses
        #{where}
        ORDER BY #{order}
        LIMIT #{offset + per_page + @dedupe_slack}
      )
      #{@dedupe}
      LIMIT #{per_page}
      OFFSET #{offset}
    )
    #{and_where(where)}
    ORDER BY #{order}
    #{@dedupe}
    LIMIT #{per_page}
    """
  end

  # Columns a user may sort by, and how each behaves when the value is absent.
  # An allow-list, not free text: the value reaches ORDER BY, so anything else
  # is an injection point. Unknown or missing => the default ranking.
  #
  # NULLS LAST throughout: sorting by "most products" must not open with a
  # screenful of businesses we have never enriched.
  @sortable %{
    "domain" => "domain",
    "tranco_rank" => "tranco_rank",
    "product_count" => "product_count",
    "price_avg" => "price_avg",
    "job_count" => "job_count",
    "seo_score" => "seo_score",
    "new_products_30d" => "new_products_30d",
    "pricing_points" => "pricing_points",
    "estimated_revenue" => "estimated_revenue",
    "depth_enriched_at" => "depth_enriched_at",
    "last_verified_at" => "last_verified_at"
  }

  @doc "Columns the UI may offer as sortable headers."
  def sortable_columns, do: Map.keys(@sortable)

  defp order_clause(nil, _dir), do: @order_by
  defp order_clause("", _dir), do: @order_by

  defp order_clause(column, dir) do
    case Map.fetch(@sortable, column) do
      {:ok, sql_column} ->
        direction = if dir in ["asc", :asc], do: "ASC", else: "DESC"
        # domain breaks ties so pagination is stable: without it two pages can
        # show the same row when many share a value.
        "#{sql_column} #{direction} NULLS LAST, domain ASC"

      :error ->
        @order_by
    end
  end

  def list(filters, opts \\ []) do
    case Clickhouse.query_raw(list_sql(filters, opts), @query_timeout) do
      {:ok, rows} -> {:ok, rows_to_maps(rows, column_names())}
      err -> err
    end
  end

  @doc "SQL for the total-row count. Public so performance tests measure the real query."
  def count_sql(filters), do: "SELECT count() FROM businesses #{build_where(filters)}"

  def count(filters) do
    case Clickhouse.query_raw(count_sql(filters), @query_timeout) do
      {:ok, [[count]]} when is_integer(count) -> {:ok, count}
      {:ok, [[count]]} when is_binary(count) -> {:ok, String.to_integer(count)}
      _ -> {:ok, 0}
    end
  end

  @doc """
  Count several filter sets in ONE query.

  The segment bar shows a count on every button, and six round trips to
  ClickHouse to draw one toolbar is six times the work for the same answer.
  A single scan with a countIf per segment costs barely more than one count,
  because the expensive part is reading the rows, not evaluating predicates.

  Takes `[{id, filters}]`, returns `%{id => count}`.
  """
  @spec count_many([{String.t() | atom(), map()}]) :: map()
  def count_many([]), do: %{}

  def count_many(labelled_filters) do
    selects =
      Enum.map_join(labelled_filters, ", ", fn {id, filters} ->
        case build_where(filters) do
          "" -> "count() AS `#{id}`"
          "WHERE " <> predicate -> "countIf(#{predicate}) AS `#{id}`"
        end
      end)

    case Clickhouse.query_raw("SELECT #{selects} FROM businesses", @query_timeout) do
      {:ok, [row]} ->
        labelled_filters
        |> Enum.map(fn {id, _} -> id end)
        |> Enum.zip(Enum.map(row, &to_count/1))
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp to_count(n) when is_integer(n), do: n

  defp to_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> v
      :error -> 0
    end
  end

  defp to_count(_), do: 0

  def get_detail(domain) when is_binary(domain) do
    sql = """
    SELECT #{Enum.join(@detail_columns, ", ")}
    FROM businesses FINAL
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

  # In the aliased export query the re-applied clause must reference d.*;
  # only `domain` collides with the contacts join, the rest pass through.
  defp qualify_where(clause), do: String.replace(clause, ~r/(?<![\w.])domain\b/, "d.domain")

  # Re-attach a WHERE clause as a conjunction after "WHERE domain IN (...)".
  defp and_where(""), do: ""
  defp and_where("WHERE " <> rest), do: "AND #{rest}"

  defp qualified_order_by do
    @order_by
    |> String.replace("tranco_rank", "d.tranco_rank")
    |> String.replace(~r/(?<![\w.])domain\b/, "d.domain")
  end

  def export_rows(filters, limit) do
    where = build_where(filters)

    # `businesses` already holds both pipelines' columns, so the only join
    # left is the contact list — the one genuinely 1:many field worth putting
    # in a CSV, flattened to a pipe-separated cell.
    sql = """
    SELECT #{Enum.map_join(@detail_columns ++ @export_depth_columns, ", ", &"d.#{&1}")},
           coalesce(c.emails, '') AS enriched_emails
    FROM businesses AS d FINAL
    LEFT JOIN (
      SELECT domain, arrayStringConcat(groupArray(email), '|') AS emails
      FROM biz_contact FINAL GROUP BY domain
    ) c ON d.domain = c.domain
    WHERE d.domain IN (
      SELECT domain FROM businesses
      #{where}
      ORDER BY #{@order_by}
      LIMIT #{limit}
    )
    #{where |> and_where() |> qualify_where()}
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
    FROM businesses FINAL
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
    FROM businesses FINAL
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
    FROM businesses FINAL
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
    FROM businesses FINAL
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
  # The "weak SEO" pitch list needs an upper bound, and it must exclude
  # businesses we never scored: NULL seo_score is "unknown", not "bad".
  defp filter_clause({:max_seo_score, v}) do
    case numeric_lte("seo_score", v) do
      [clause] -> ["(#{clause} AND seo_score IS NOT NULL)"]
      other -> other
    end
  end

  defp filter_clause({:ats_platform, v}) when is_binary(v) and v != "",
    do: ["ats_platform = '#{esc(v)}'"]

  # Parked domains / default storefronts (see BusinessClassifier.junk_reason/1).
  # Kept opt-in for now: measure the junk rate with the golden set first, flip
  # to exclude-by-default once the detector's precision is verified.
  defp filter_clause({:exclude_junk, "true"}), do: ["is_junk = ''"]
  defp filter_clause({:has_pricing, "true"}), do: ["pricing_points > 0"]
  defp filter_clause({:has_email, "true"}), do: ["http_emails != ''"]
  defp filter_clause({:hiring, "true"}), do: ["job_count > 0"]


  defp filter_clause({:revenue, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["#{@shown_revenue} = '#{esc(hd(values))}'"],
    else: ["#{@shown_revenue} IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
  end

  defp filter_clause({:employees, v}) when is_binary(v) and v != "" do
    values = String.split(v, ",", trim: true) |> Enum.map(&String.trim/1)
    if length(values) == 1, do: ["#{@shown_employees} = '#{esc(hd(values))}'"],
    else: ["#{@shown_employees} IN (#{Enum.map_join(values, ",", &"'#{esc(&1)}'")})" ]
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

  # `businesses` has no enriched_at: the compactor records `as_of` — the
  # newest crawl of any kind we hold for that domain — which is exactly what
  # "freshness" means to a customer.
  defp filter_clause({:freshness, "24h"}) do
    ["as_of >= now() - INTERVAL 1 DAY"]
  end

  defp filter_clause({:freshness, "7d"}) do
    ["as_of >= now() - INTERVAL 7 DAY"]
  end

  defp filter_clause({:freshness, "30d"}) do
    ["as_of >= now() - INTERVAL 30 DAY"]
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
