defmodule LS.Clickhouse.Tech do
  @moduledoc """
  Reads for the public technology pages: `/tech/:slug`, `/top/*`,
  `/compare/*`, the directory and the sitemap.

  Every query here hits `tech_index` (migration 024, kept fresh by
  `LS.TechIndex`): one row per (technology, titled domain), sorted by
  (tech, rank, domain). A technology is one contiguous key range and the
  ranked top-N is its first granules. Before 2026-09-09 these were
  `http_tech LIKE '%X%'` scans of the 193M-row domains_fast view: 29.5s
  average, 119s p95, 54,000 CPU-seconds a day, and the shape of the 09-07
  "Search unavailable" storm. Names are bound as query parameters, never
  interpolated. Matching is by exact token (see the migration for the
  meaning change: "React" no longer counts "React Router").

  Split out of `LS.Clickhouse` the same day: that module was 2,200 lines,
  and the index readers are one coherent surface with one table.
  """

  alias LS.Clickhouse

  @store_cols "domain, http_title, http_tech, country, tranco_rank"
  @store_cols_full @store_cols <>
                     ", http_response_time, http_language, rdap_registrar, rdap_domain_created_at, " <>
                     "http_status, bgp_asn_org, dns_mx, http_emails, majestic_rank"
  @by_rank "ORDER BY rank, domain"

  def stores_by_tech(tech_name, limit \\ 100) do
    Clickhouse.query("SELECT #{@store_cols} FROM tech_index WHERE tech = {t:String} #{@by_rank} LIMIT #{int(limit)}", %{t: tech_name})
  end

  def tech_store_count(tech_name) do
    case Clickhouse.query("SELECT count() FROM tech_index WHERE tech = {t:String}", %{t: tech_name}) do
      {:ok, [[count]]} -> count
      _ -> 0
    end
  end

  # ── Tech profile (rich) ──

  def stores_by_tech_full(tech_name, limit \\ 100) do
    Clickhouse.query("SELECT #{@store_cols_full} FROM tech_index WHERE tech = {t:String} #{@by_rank} LIMIT #{int(limit)}", %{t: tech_name})
  end

  # These reads are milliseconds now, but the page assembles six of them and
  # a public SEO page's population does not move hour to hour, so the results
  # still cache. The TTLs predate the index (when each was a full scan).
  @tech_stats_ttl_ms :timer.minutes(15)
  @tech_dist_ttl :timer.hours(6)

  def tech_stats(tech_name) do
    LS.LandingCache.cached({:tech_stats, tech_name}, @tech_stats_ttl_ms, fn ->
      Clickhouse.query(
        """
        SELECT
          count() AS total,
          avg(http_response_time) AS avg_response_time,
          countIf(http_status = 200) AS responding_count,
          countIf(tranco_rank IS NOT NULL AND tranco_rank <= 100000) AS top_100k_count
        FROM tech_index
        WHERE tech = {t:String}
        -- JSON output quotes UInt64 by default, so count() arrived as "766890"
        -- (a string) and every consumer doing arithmetic on it broke. Scoped to
        -- this query: other call sites may rely on the string form.
        SETTINGS output_format_json_quote_64bit_integers = 0
        """,
        %{t: tech_name}
      )
    end)
  end

  def tech_language_distribution(tech_name) do
    LS.LandingCache.cached({:tech_language_distribution, tech_name}, @tech_dist_ttl, fn ->
      tech_distribution("http_language", tech_name)
    end)
  end

  def tech_hosting_distribution(tech_name) do
    LS.LandingCache.cached({:tech_hosting_distribution, tech_name}, @tech_dist_ttl, fn ->
      tech_distribution("bgp_asn_org", tech_name)
    end)
  end

  def tech_registrar_distribution(tech_name) do
    LS.LandingCache.cached({:tech_registrar_distribution, tech_name}, @tech_dist_ttl, fn ->
      tech_distribution("rdap_registrar", tech_name)
    end)
  end

  def tech_country_distribution(tech_name), do: tech_distribution("country", tech_name)

  # `column` is one of four literals above, never user input.
  defp tech_distribution(column, tech_name) do
    Clickhouse.query(
      """
      SELECT #{column}, count() AS cnt FROM tech_index
      WHERE tech = {t:String} AND #{column} != ''
      GROUP BY #{column} ORDER BY cnt DESC LIMIT 10
      """,
      %{t: tech_name}
    )
  end

  def tech_co_occurring(tech_name) do
    LS.LandingCache.cached({:tech_co_occurring, tech_name}, @tech_dist_ttl, fn ->
      Clickhouse.query(
        """
        SELECT arrayJoin(splitByChar('|', http_tech)) AS other, count() AS cnt
        FROM tech_index
        WHERE tech = {t:String}
        GROUP BY other HAVING other != {t:String} AND cnt >= 2
        ORDER BY cnt DESC LIMIT 20
        """,
        %{t: tech_name}
      )
    end)
  end

  # ── VS / Compare pages ──

  @doc """
  Everything `/compare/a-vs-b` renders.

  Every sub-query DEGRADES instead of raising. When these were full scans
  (~55s cold on a busy box) each of the four below was a hard `{:ok, x} = ...`
  match while `both_count` already fell back to 0, so a single ClickHouse
  timeout raised MatchError and Phoenix served 500 on a public SEO page
  (2026-08-24, /compare/klaviyo-vs-mailchimp mid-compaction). A page missing
  one panel beats a 500, and the rule stays now that the reads are cheap.

  Sets `degraded: true` when anything fell back, so the caller can decline to
  cache a half-empty page for the profile's full TTL.
  """
  def compare_techs(tech_a, tech_b) do
    count_a = tech_store_count(tech_a)
    count_b = tech_store_count(tech_b)
    results = [stores_by_tech(tech_a, 10), stores_by_tech(tech_b, 10),
               tech_country_distribution(tech_a), tech_country_distribution(tech_b)]
    [stores_a, stores_b, countries_a, countries_b] = Enum.map(results, &ok_or_empty/1)
    degraded? = Enum.any?(results, &(not match?({:ok, _}, &1)))

    both_count =
      case Clickhouse.query(
             "SELECT count() FROM tech_index WHERE tech = {a:String} AND has(splitByChar('|', http_tech), {b:String})",
             %{a: tech_a, b: tech_b}
           ) do
        {:ok, [[c]]} -> c
        _ -> 0
      end

    %{
      tech_a: %{name: tech_a, count: count_a, stores: stores_a, countries: countries_a},
      tech_b: %{name: tech_b, count: count_b, stores: stores_b, countries: countries_b},
      both_count: both_count,
      degraded: degraded?
    }
  end

  @doc false
  def ok_or_empty({:ok, rows}), do: rows
  def ok_or_empty(_), do: []

  # ── Top / Ranking pages ──

  # `tech = 'Shopify'` is the indexed form of `is_shopify = 1` (the column
  # materialises `http_tech LIKE '%Shopify%'`, and Shopify is the only token
  # containing that word: 1,198,500 rows either way on 2026-09-09).
  def top_stores_by_country(country_code, limit \\ 50) do
    LS.UICache.fetch(:top_page, {:country, country_code, limit}, fn ->
      Clickhouse.query(
        "SELECT #{@store_cols} FROM tech_index WHERE tech = 'Shopify' AND country = {c:String} #{@by_rank} LIMIT #{int(limit)}",
        %{c: country_code}
      )
    end)
  end

  def top_stores_using_tech(tech_name, limit \\ 50) do
    LS.UICache.fetch(:top_page, {:tech, tech_name, limit}, fn -> top_stores_using_tech_uncached(tech_name, limit) end)
  end

  defp top_stores_using_tech_uncached(tech_name, limit) do
    Clickhouse.query(
      "SELECT #{@store_cols} FROM tech_index WHERE tech = {t:String} AND is_shopify = 1 #{@by_rank} LIMIT #{int(limit)}",
      %{t: tech_name}
    )
  end

  def top_stores_using_tech_in_country(tech_name, country_code, limit \\ 50) do
    Clickhouse.query(
      "SELECT #{@store_cols} FROM tech_index WHERE tech = {t:String} AND is_shopify = 1 AND country = {c:String} #{@by_rank} LIMIT #{int(limit)}",
      %{t: tech_name, c: country_code}
    )
  end

  # ── Directory / Hub pages ──

  def tech_directory do
    Clickhouse.query("SELECT tech, count() AS cnt FROM tech_index GROUP BY tech HAVING cnt >= 5 ORDER BY cnt DESC LIMIT 500")
  end

  # /tech/:slug and /compare/:slug resolve their slug against this list on
  # every request; a GROUP BY over the whole index is ~1s, so it caches.
  @tech_directory_ttl :timer.hours(1)

  def tech_directory_cached do
    LS.LandingCache.cached(:tech_directory, @tech_directory_ttl, &tech_directory/0)
  end

  @doc """
  URL slug for a tech name. Must stay in sync with the slug the sitemap emits
  and with `canonical_tech_name/1`, or /tech/* and /compare/* 404.
  """
  def tech_slug(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
  end

  @doc """
  Resolve a URL slug back to the exact string stored in `http_tech`.

  Callers used to rebuild the name with `split("-") |> map(&capitalize/1)`, which
  silently mangles every tech that isn't Title Case: "vue-js" -> "Vue Js" (stored
  "Vue.js"), "jquery" -> "Jquery" (stored "jQuery"), "paypal" -> "Paypal" (stored
  "PayPal"). ClickHouse LIKE is case-sensitive, so those pages rendered with zero
  stores and empty distributions. Returns nil when the slug matches no known tech.
  """
  def canonical_tech_name(slug) when is_binary(slug) do
    case tech_directory_cached() do
      {:ok, rows} -> Enum.find_value(rows, fn [name | _] -> if tech_slug(name) == slug, do: name end)
      _ -> nil
    end
  end

  def country_directory do
    # HAVING >= 10: the sitemap emits /top/shopify-stores-<cc> from this list
    # and the page needs enough stores to render a list worth indexing. Seven
    # thin countries (CM, LY, DZ...) were being emitted and 404ing for Google
    # — same contract as techs: never offer a URL the page cannot serve.
    Clickhouse.query("""
    SELECT country, count() AS cnt FROM tech_index
    WHERE tech = 'Shopify' AND country != ''
    GROUP BY country
    HAVING cnt >= 10
    ORDER BY cnt DESC
    """)
  end

  def all_shopify_domains(limit \\ 49_000) do
    Clickhouse.query("SELECT domain FROM tech_index WHERE tech = 'Shopify' #{@by_rank} LIMIT #{int(limit)}")
  end

  @doc """
  Tech names that at least `min` SHOPIFY stores actually use — the only techs
  the sitemap may emit /top/shopify-stores-using-* URLs for.

  The sitemap used to emit that URL for EVERY known tech, but the page 404s
  when the Shopify intersection is empty (Pendo, enterprise SaaS tools...), so
  the sitemap advertised 404s to Google. Same data-contract rule as the UI:
  never offer a link that matches no rows. `min` defaults to 3 so one
  misdetected store cannot resurrect a URL that will soon 404 again.

  One pass over the index's `is_shopify` column (147M narrow rows, about a
  second); cached because the sitemap and the cache warmer both ask.
  """
  def shopify_tech_names(min \\ 3) do
    LS.LandingCache.cached({:shopify_tech_names, min}, @tech_dist_ttl, fn ->
      Clickhouse.query("""
      SELECT tech, count() AS n FROM tech_index
      WHERE is_shopify = 1
      GROUP BY tech
      HAVING n >= #{int(max(1, min))}
      ORDER BY n DESC
      """)
    end)
  end

  @doc """
  Shopify-store counts per (tech, country) for the given techs, in ONE query.
  Returns %{{tech, country} => count}; feeds the /top/shopify-stores-using-X-in-CC
  sitemap section, thresholded by the caller.
  """
  def tech_country_matrix(techs) when is_list(techs) and techs != [] do
    LS.LandingCache.cached({:tech_country_matrix, Enum.sort(techs)}, @tech_dist_ttl, fn ->
      Clickhouse.query(
        """
        SELECT tech, country, count() FROM tech_index
        WHERE tech IN {techs:Array(String)} AND is_shopify = 1 AND country != ''
        GROUP BY tech, country
        """,
        %{techs: Clickhouse.array_param(techs)}
      )
    end)
    |> case do
      {:ok, rows} -> Map.new(rows, fn [tech, country, count] -> {{tech, country}, count} end)
      _ -> %{}
    end
  end

  def all_tech_slugs do
    case tech_directory() do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [tech | _] -> tech end)}
      err -> err
    end
  end

  # LIMITs and thresholds are interpolated as integers only.
  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0
end
