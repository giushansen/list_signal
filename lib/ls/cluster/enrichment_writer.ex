defmodule LS.Cluster.EnrichmentWriter do
  @moduledoc """
  Writes enrichment-lane results into the `biz_*` child tables. Master-only.

  This module is the *only* writer of those tables, and it writes nothing
  else — in particular it never touches `domains_history` or `domains_current`.
  That separation is what makes it structurally impossible for pipeline 2 to
  blank pipeline 1's data, which is the failure that cost ~7.8M spoiled
  domains before this design.

  Rows are appended; the tables are `ReplacingMergeTree` keyed on
  `(domain, …)`, so re-enriching a domain updates in place at merge time
  rather than duplicating.
  """

  require Logger

  alias LS.Clickhouse

  @doc """
  Persist a batch of results from `LS.Enrichment.Agent.enrich/1`.

  Each result carries `contacts`, `jobs`, `pricing` (child rows) and `summary`
  (1:1 columns that the compactor later folds into `businesses`).
  """
  @spec write([map()]) :: :ok
  def write([]), do: :ok

  def write(results) do
    insert("biz_contact", ~w(domain email source_page seen_at),
      Enum.flat_map(results, & &1[:contacts] || []))

    # The agent stamps :seen_at on every job row (crawl time). The put_new is
    # only a guard against an older agent still in flight during a rolling
    # deploy — an empty posted_at used to leak in here and fail the whole
    # batch's DateTime parse, which is why prod biz_career stayed at 0 rows.
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

    insert("biz_career", ~w(domain job_id title location url posted_at seen_at),
      results |> Enum.flat_map(& &1[:jobs] || []) |> Enum.map(&Map.put_new(&1, :seen_at, now)))

    insert("biz_pricing", ~w(domain price currency seen_at),
      Enum.flat_map(results, & &1[:pricing] || []))

    insert("biz_products",
      ~w(domain product_id title handle vendor product_type price available
         variant_count image_count created_at seen_at),
      Enum.flat_map(results, & &1[:products] || []))

    insert("biz_collections",
      ~w(domain collection_id title handle products_count updated_at seen_at),
      Enum.flat_map(results, & &1[:collections] || []))

    insert("biz_enrichment", summary_columns(),
      results |> Enum.map(& &1[:summary]) |> Enum.reject(&(&1 in [nil, %{}])))

    :ok
  end

  @doc "Columns of `biz_enrichment` — the 1:1 signals the compactor merges into `businesses`."
  def summary_columns do
    ~w(domain enriched_at render_engine
       product_count price_min price_avg price_max new_products_30d last_product_at
       oos_ratio discount_depth vendor_count catalog_age_days product_types
       job_count ats_platform job_departments job_locations
       seo_score seo_issues seo_word_count seo_alt_ratio
       perf_lcp_ms perf_cls perf_ttfb_ms
       about_text mission hq_location job_locations_top positions_overview)
  end

  # ── insertion ──────────────────────────────────────────────────────────────

  defp insert(_table, _cols, []), do: :ok

  defp insert(table, cols, rows) do
    tsv = Enum.map_join(rows, "\n", fn row -> Enum.map_join(cols, "\t", &tsv_value(row, &1)) end)
    sql = "INSERT INTO #{table} (#{Enum.join(cols, ", ")}) FORMAT TabSeparated"

    case Clickhouse.insert_raw(sql, tsv) do
      :ok -> :ok
      {:error, reason} -> Logger.error("[ENRICH] insert #{table} failed: #{inspect(reason)}")
    end
  end

  # ClickHouse TabSeparated: NULLs are \N, and tabs/newlines must be escaped or
  # they silently shift every following column.
  defp tsv_value(row, col) do
    case Map.get(row, String.to_existing_atom(col)) do
      nil -> "\\N"
      true -> "1"
      false -> "0"
      v when is_binary(v) -> v |> String.replace("\t", " ") |> String.replace("\n", " ")
      v -> to_string(v)
    end
  rescue
    ArgumentError -> "\\N"
  end
end
