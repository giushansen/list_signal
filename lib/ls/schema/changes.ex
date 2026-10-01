defmodule LS.Schema.Changes do
  @moduledoc """
  The `changes_log` table and the SQL that fills it (data model v2, 2026-10-01).

  One row per change of one tracked column on one domain:

      domain, field, change, value, prev_value, changed_at

  `field` is the `businesses` column name, `change` is one of added,
  removed, changed, started, stopped, down, back. The tracked columns and
  their rule live on the column spec (`LS.Schema.Columns.tracked/0`), so a
  signal is declared next to the column it watches and nowhere else.

  Detection runs inside the compaction pass: the pass first materialises the
  freshly folded rows into a scratch table, then `detect_sql/1` compares that
  table with the current `businesses` row of the same domains, then the
  scratch rows are inserted into `businesses`. Comparing compiled row to
  compiled row is exact (every fold rule has already applied, a stub crawl
  never masquerades as a removal) and is what `biz_signal` already did for
  tech, apps and jobs with lagInFrame.

  Containers are never tracked as a whole: only scalar and array columns of
  `businesses` can appear in `tracked/0`. First fills are not changes: a
  domain with no `businesses` row yet emits nothing (INNER JOIN), and a set
  rule requires both sides non-empty, so the first crawl that finds a
  technology list does not "add" forty technologies.
  """

  alias LS.Schema.{Columns, Tables}

  @doc "CREATE TABLE for changes_log."
  def ddl(table \\ Tables.changes_log()) do
    """
    CREATE TABLE IF NOT EXISTS #{table} (
      `domain` String,
      `field` LowCardinality(String),
      `change` LowCardinality(String),
      `value` String,
      `prev_value` String,
      `changed_at` DateTime,
      INDEX idx_domain domain TYPE bloom_filter(0.01) GRANULARITY 1,
      PROJECTION by_domain (SELECT * ORDER BY domain, changed_at)
    ) ENGINE = ReplacingMergeTree
    ORDER BY (field, value, changed_at, domain)
    TTL changed_at + toIntervalDay(730)
    SETTINGS index_granularity = 8192, deduplicate_merge_projection_mode = 'rebuild'
    """
  end

  @doc "CREATE TABLE for the page store."
  def pages_ddl(table \\ Tables.http_pages()) do
    """
    CREATE TABLE IF NOT EXISTS #{table} (
      `domain` String,
      `page_kind` LowCardinality(String),
      `http_fetched_at` DateTime,
      `http_header_tags` Array(LowCardinality(String)),
      `http_header_texts` Array(String) CODEC(ZSTD(3)),
      `http_body_tags` Array(LowCardinality(String)),
      `http_body_texts` Array(String) CODEC(ZSTD(3)),
      `http_footer_tags` Array(LowCardinality(String)),
      `http_footer_texts` Array(String) CODEC(ZSTD(3)),
      `http_jsonld` String CODEC(ZSTD(3))
    ) ENGINE = ReplacingMergeTree(http_fetched_at)
    ORDER BY (domain, page_kind)
    SETTINGS index_granularity = 8192
    """
  end

  @doc "CREATE TABLE for the tech catalog mirror the fold reads."
  def catalog_ddl(table \\ Tables.tech_catalog()) do
    """
    CREATE TABLE IF NOT EXISTS #{table} (
      `name` String,
      `category` LowCardinality(String),
      `ecosystem` LowCardinality(String)
    ) ENGINE = ReplacingMergeTree
    ORDER BY name
    """
  end

  @doc """
  INSERT ... SELECT that records every change between the scratch table of
  freshly compiled rows (`n`) and the current `businesses` rows (`o`).
  """
  def detect_sql(scratch, businesses \\ Tables.businesses(), changes \\ Tables.changes_log()) do
    rules = Enum.map_join(Columns.tracked(), ",\n        ", &rule_sql/1)
    cols = Columns.tracked() |> Enum.map(&elem(&1, 0))

    """
    INSERT INTO #{changes} (domain, field, change, value, prev_value, changed_at)
    SELECT n.domain, ch.1, ch.2, ch.3, ch.4, ch.5
    FROM #{scratch} AS n
    INNER JOIN (
      SELECT domain, #{Enum.join(cols, ", ")}
      FROM #{businesses}
      WHERE domain IN (SELECT domain FROM #{scratch})
      ORDER BY compiled_at DESC
      LIMIT 1 BY domain
    ) AS o ON n.domain = o.domain
    ARRAY JOIN arrayConcat(
        #{rules}
    ) AS ch
    SETTINGS join_use_nulls = 1, max_threads = 2, max_execution_time = 115
    """
  end

  # When a change happened: the observation that produced the column.
  defp at(field) do
    cond do
      String.starts_with?(field, ["shop_", "hr_", "http_deep_"]) -> "ifNull(n.http_deep_last_seen_at, n.http_last_checked_at)"
      String.starts_with?(field, "verified_") -> "ifNull(n.verified_at, n.http_last_checked_at)"
      String.starts_with?(field, "news_") -> "ifNull(n.news_last_seen_at, n.http_last_checked_at)"
      true -> "n.http_last_checked_at"
    end
  end

  defp tuple(field, change, value, prev, at), do: "('#{field}', '#{change}', #{value}, #{prev}, #{at})"

  @doc false
  def rule_sql({f, :set, _type}) do
    """
    arrayFilter(x -> notEmpty(n.#{f}) AND notEmpty(o.#{f}), arrayConcat(
          arrayMap(x -> #{tuple(f, "added", "toString(x)", "''", at(f))}, arrayFilter(x -> NOT has(o.#{f}, x), n.#{f})),
          arrayMap(x -> #{tuple(f, "removed", "toString(x)", "''", at(f))}, arrayFilter(x -> NOT has(n.#{f}, x), o.#{f}))))\
    """
  end

  def rule_sql({f, :set_added, _type}) do
    "arrayMap(x -> #{tuple(f, "added", "toString(x)", "''", at(f))}, arrayFilter(x -> NOT has(o.#{f}, x), n.#{f}))"
  end

  def rule_sql({f, :changed, type}) do
    if string_type?(type) do
      "arrayFilter(x -> n.#{f} != o.#{f} AND o.#{f} != '' AND n.#{f} != '', [#{tuple(f, "changed", "toString(n.#{f})", "toString(o.#{f})", at(f))}])"
    else
      "arrayFilter(x -> n.#{f} IS NOT NULL AND o.#{f} IS NOT NULL AND n.#{f} != o.#{f}, [#{tuple(f, "changed", "toString(n.#{f})", "toString(o.#{f})", at(f))}])"
    end
  end

  def rule_sql({f, :started_stopped, _type}) do
    """
    arrayConcat(
          arrayFilter(x -> coalesce(o.#{f}, 0) = 0 AND coalesce(n.#{f}, 0) > 0, [#{tuple(f, "started", "toString(n.#{f})", "'0'", at(f))}]),
          arrayFilter(x -> coalesce(o.#{f}, 0) > 0 AND n.#{f} = 0, [#{tuple(f, "stopped", "'0'", "toString(o.#{f})", at(f))}]))\
    """
  end

  def rule_sql({f, :down_back, _type}) do
    ok = fn side -> "(#{side}.#{f} BETWEEN 200 AND 399)" end

    """
    arrayConcat(
          arrayFilter(x -> #{ok.("o")} AND n.#{f} IS NOT NULL AND NOT #{ok.("n")}, [#{tuple(f, "down", "toString(n.#{f})", "toString(o.#{f})", at(f))}]),
          arrayFilter(x -> o.#{f} IS NOT NULL AND NOT #{ok.("o")} AND #{ok.("n")}, [#{tuple(f, "back", "toString(n.#{f})", "toString(o.#{f})", at(f))}]))\
    """
  end

  def rule_sql({f, {:pct, p}, _type}) do
    "arrayFilter(x -> o.#{f} > 0 AND n.#{f} IS NOT NULL AND abs(toFloat64(n.#{f}) - toFloat64(o.#{f})) / toFloat64(o.#{f}) >= #{p}, [#{tuple(f, "changed", "toString(n.#{f})", "toString(o.#{f})", at(f))}])"
  end

  defp string_type?(type), do: String.contains?(type, "String")

  @doc """
  One-time import of the v1 `biz_signal` rows. tech and app events become
  `http_tech` added/removed (aliases resolved to the canonical name), hiring
  events become `hr_job_count` started/stopped.
  """
  def import_v1_sql(from \\ "biz_signal", to \\ Tables.changes_log()) do
    {from_a, to_a} = LS.Tech.Catalog.alias_arrays()

    """
    INSERT INTO #{to} (domain, field, change, value, prev_value, changed_at)
    SELECT domain,
           if(kind IN ('tech_added', 'tech_removed', 'app_added', 'app_removed'), 'http_tech', 'hr_job_count') AS field,
           multiIf(kind LIKE '%_added', 'added', kind LIKE '%_removed', 'removed', kind = 'started_hiring', 'started', 'stopped') AS change,
           if(field = 'http_tech', transform(value, #{lit(from_a)}, #{lit(to_a)}, value), value) AS value,
           '' AS prev_value,
           changed_at
    FROM #{from}
    """
  end

  defp lit(list), do: "[" <> Enum.map_join(list, ", ", &"'#{String.replace(&1, "'", "\\'")}'") <> "]"
end
