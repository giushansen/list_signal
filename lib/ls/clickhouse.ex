defmodule LS.Clickhouse do
  @moduledoc "ClickHouse query interface for ListSignal web pages."

  @ch_url "http://127.0.0.1:8123/"
  @ch_db "ls"
  # Was 10s. country_expr/0 is a ~100-branch multiIf and used to be evaluated over
  # 81M rows on every /top/* request, taking 8-11s — so the query lost the race and
  # the controller turned the error into a 404. That expression is now a
  # materialised column (see country_expr/0), which brought the same query to
  # ~1.8s, but the headroom stays: a timeout here costs a page, and the master has
  # only 3 cores to share with the ingest pipeline.
  @timeout 25_000

  # ── Landing page ──

  def shopify_store_count do
    case query("SELECT count() FROM domains_fast WHERE is_shopify = 1") do
      {:ok, [[count]]} -> count
      _ -> nil
    end
  end

  # The landing-page teaser now sells what buyers actually pay for (revenue
  # bracket, catalogue, hiring, reachability) instead of the commodity columns
  # every scanner shows. Prefers deep-enriched stores so the depth cells are
  # populated, not dashes.
  def sample_shopify_stores(limit \\ 6) do
    query("""
    SELECT domain, http_title, inferred_country, tranco_rank,
           estimated_revenue, business_model, product_count, price_avg,
           job_count, seo_score, http_emails != '' AS has_contact
    FROM businesses FINAL
    WHERE positionCaseInsensitive(http_tech, 'shopify') > 0
      AND http_title != '' AND depth_enriched_at IS NOT NULL
      AND estimated_revenue != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  @doc """
  Aggregate hiring stats for the public /hiring page. Deliberately coarse:
  department-level counts sell the depth of the dataset without exposing
  which boards we read or any per-company detail a competitor could replay.
  """
  def hiring_overview do
    with {:ok, [[companies, roles]]} <-
           query("SELECT countIf(job_count > 0), toUInt64(sum(job_count)) FROM businesses FINAL SETTINGS max_threads=2"),
         {:ok, depts} <-
           query("""
           SELECT dept, count() AS companies FROM (
             SELECT arrayJoin(splitByChar('|', job_departments)) AS dept
             FROM businesses FINAL
             WHERE job_count > 0 AND job_departments != ''
           )
           WHERE dept != ''
           GROUP BY dept ORDER BY companies DESC LIMIT 12
           SETTINGS max_threads=2, max_bytes_before_external_group_by=1000000000
           """) do
      {:ok, %{companies: companies, roles: roles, departments: depts}}
    end
  end

  # Bot-wall pages the crawler sometimes captures as titles; a public feed
  # printing "Verifying your connection..." as a store name looks broken
  # (reported on /new-stores, 2026-08-16).
  @challenge_titles [
    "Verifying your connection", "Just a moment", "Attention Required",
    "Access denied", "Security check", "Checking your browser",
    "One moment, please", "Antibot", "Please wait"
  ]

  @doc "Title prefixes/fragments of bot-challenge pages — exposed for tests."
  def challenge_titles, do: @challenge_titles

  defp not_challenge_sql(col) do
    @challenge_titles
    |> Enum.map(&"positionCaseInsensitive(#{col}, '#{escape(&1)}') = 0")
    |> Enum.join(" AND ")
  end

  def recent_stores(limit \\ 20) do
    query("""
    SELECT domain, country, http_title, http_tech, enriched_at
    FROM domains_fast
    WHERE is_shopify = 1 AND http_title != '' AND #{not_challenge_sql("http_title")}
    ORDER BY enriched_at DESC
    LIMIT #{limit}
    """)
  end

  @doc """
  Pipeline 3's verified values for one domain from `businesses` (a point read
  on the primary key). Empty map when nothing is verified — callers fall back
  to the estimate.
  """
  @spec verified_for(String.t()) :: map()
  def verified_for(domain) do
    case query("""
         SELECT verified_revenue, verified_revenue_source, verified_employees, verified_employees_source, mission_summary
         FROM businesses WHERE domain = '#{escape(domain)}' ORDER BY as_of DESC LIMIT 1
         """) do
      {:ok, [[rev, rev_src, emp, emp_src, mission]]} ->
        %{revenue: rev, revenue_source: rev_src, employees: emp, employees_source: emp_src, mission_summary: mission}

      _ -> %{}
    end
  end

  @doc """
  SEO score (0-100) for the free checker badge.

  Stored score first (browser lane); when absent — only ~64% of businesses
  have one — a live content-only audit of the homepage via the polite HTTP
  client, cached 6h so a CDN-cold page costs at most one fetch per domain
  per window. nil only when the page cannot be fetched at all.
  """
  def get_seo_score(domain) do
    case query("SELECT seo_score FROM businesses WHERE domain = '#{escape(domain)}' LIMIT 1") do
      {:ok, [[n]]} when is_number(n) and n > 0 ->
        round(n)

      _ ->
        LS.LandingCache.cached({:seo_live, domain}, :timer.hours(6), fn ->
          {:ok, live_seo_score(domain)}
        end)
        |> case do
          {:ok, score} -> score
          _ -> nil
        end
    end
  end

  defp live_seo_score(domain) do
    with {:ok, %{a: [ip | _]}} <- LS.DNS.Resolver.lookup(domain),
         {:ok, %{body: html}} when is_binary(html) and html != "" <- LS.HTTP.Client.fetch(domain, ip),
         %{seo_score: score} when is_integer(score) <- LS.Enrichment.SEO.audit(html) do
      score
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Latest classified businesses for the public /saas feed."
  def recent_by_model(models, limit \\ 50) when is_list(models) do
    list = models |> Enum.map(&"'#{escape(&1)}'") |> Enum.join(",")

    query("""
    SELECT domain, inferred_country, http_title, http_tech, as_of
    FROM businesses
    WHERE business_model IN (#{list}) AND is_junk = '' AND http_title != ''
      AND classification_confidence >= 0.5 AND #{not_challenge_sql("http_title")}
    ORDER BY as_of DESC
    LIMIT #{limit}
    """)
  end

  # ── Store profile ──

  def get_store(domain) when is_binary(domain) do
    query("SELECT * FROM domains_current FINAL WHERE domain = '#{escape(domain)}' LIMIT 1")
  end

  # ── Tech profile ──

  def stores_by_tech(tech_name, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank
    FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def stores_by_tech_ilike(search, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank
    FROM domains_fast
    WHERE lower(http_tech) LIKE '%#{escape(String.downcase(search))}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def tech_store_count(tech_name) do
    case query("SELECT count() FROM domains_fast WHERE http_tech LIKE '%#{escape(tech_name)}%'") do
      {:ok, [[count]]} -> count
      _ -> 0
    end
  end

  # ── Tech profile (rich) ──

  def stores_by_tech_full(tech_name, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank,
           http_response_time, http_language, rdap_registrar,
           rdap_domain_created_at, http_status, bgp_asn_org,
           dns_mx, http_emails, majestic_rank
    FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def stores_by_tech_full_ilike(search, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank,
           http_response_time, http_language, rdap_registrar,
           rdap_domain_created_at, http_status, bgp_asn_org,
           dns_mx, http_emails, majestic_rank
    FROM domains_fast
    WHERE lower(http_tech) LIKE '%#{escape(String.downcase(search))}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  # Aggregating over every row matching a popular tech (Google Analytics matches
  # ~1.5M rows) regularly runs 5-10s on a loaded master. At the default 10s
  # timeout this silently failed and the page fell back to fabricated numbers,
  # so give it room and cache the result for 15 minutes.
  @tech_stats_timeout 30_000
  @tech_stats_ttl_ms :timer.minutes(15)
  # The four per-tech distributions below were the only uncached queries on the
  # tech page, and each full-scans 153.7M rows of domains_fast: together
  # 88,000 CPU-seconds a day. They describe a technology's whole population,
  # which does not move hour to hour, so they cache for six hours.
  @tech_dist_ttl :timer.hours(6)

  def tech_stats(tech_name) do
    LS.LandingCache.cached({:tech_stats, tech_name}, @tech_stats_ttl_ms, fn ->
      query_raw(
        """
        SELECT
          count() AS total,
          avg(http_response_time) AS avg_response_time,
          countIf(http_status = 200) AS responding_count,
          countIf(tranco_rank IS NOT NULL AND tranco_rank <= 100000) AS top_100k_count
        FROM domains_fast
        WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
        -- JSON output quotes UInt64 by default, so count() arrived as "766890"
        -- (a string) and every consumer doing arithmetic on it broke. Scoped to
        -- this query: other call sites may rely on the string form.
        SETTINGS output_format_json_quote_64bit_integers = 0
        """,
        @tech_stats_timeout
      )
    end)
  end

  def tech_language_distribution(tech_name) do
    LS.LandingCache.cached({:tech_language_distribution, tech_name}, @tech_dist_ttl, fn ->
    query("""
    SELECT http_language, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_language != ''
    GROUP BY http_language ORDER BY cnt DESC LIMIT 10
    """)
    end)
  end

  def tech_hosting_distribution(tech_name) do
    LS.LandingCache.cached({:tech_hosting_distribution, tech_name}, @tech_dist_ttl, fn ->
    query("""
    SELECT bgp_asn_org, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND bgp_asn_org != ''
    GROUP BY bgp_asn_org ORDER BY cnt DESC LIMIT 10
    """)
    end)
  end

  def tech_registrar_distribution(tech_name) do
    LS.LandingCache.cached({:tech_registrar_distribution, tech_name}, @tech_dist_ttl, fn ->
    query("""
    SELECT rdap_registrar, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND rdap_registrar != ''
    GROUP BY rdap_registrar ORDER BY cnt DESC LIMIT 10
    """)
    end)
  end

  def tech_co_occurring(tech_name) do
    LS.LandingCache.cached({:tech_co_occurring, tech_name}, @tech_dist_ttl, fn ->
    query("""
    SELECT arrayJoin(splitByString('|', http_tech)) AS tech, count() AS cnt
    FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    GROUP BY tech HAVING tech != '#{escape(tech_name)}' AND cnt >= 2
    ORDER BY cnt DESC LIMIT 20
    """)
    end)
  end

  # ── VS / Compare pages ──

  @doc """
  Everything `/compare/a-vs-b` renders.

  Every sub-query DEGRADES instead of raising. These are the heaviest scans on
  the public site (~55s cold on a busy box), and each of the four below used to
  be a hard `{:ok, x} = ...` match while `both_count` already fell back to 0 —
  so a single ClickHouse timeout raised MatchError and Phoenix served 500 on a
  public SEO page. Seen 2026-08-24 on /compare/klaviyo-vs-mailchimp whenever
  the compactor was mid-pass. A page missing one panel beats a 500.

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
    both_count = case query("""
    SELECT count() FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_a)}%' AND http_tech LIKE '%#{escape(tech_b)}%'
    """) do
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

  def tech_country_distribution(tech_name) do
    query("""
    SELECT country, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND country != ''
    GROUP BY country ORDER BY cnt DESC LIMIT 10
    """)
  end

  # ── Top / Ranking pages ──

  # Cached: measured 2026-08-27 as the single most expensive query on the box,
  # 160 calls in 6 hours at ~100s and 9.75 GiB each, about 0.75 of a core
  # continuously. `domains_fast` is a VIEW with no sorting key, so every call
  # re-scans the base table; there is nothing to index away. These are public
  # ranking pages whose contents move far slower than the TTL, so the answer is
  # to compute them once an hour instead of once a request.
  def top_stores_by_country(country_code, limit \\ 50) do
    LS.UICache.fetch(:top_page, {:country, country_code, limit}, fn ->
      query("""
      SELECT domain, http_title, http_tech, country, tranco_rank
      FROM domains_fast
      WHERE is_shopify = 1 AND country = '#{escape(country_code)}' AND http_title != ''
      ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
      """)
    end)
  end

  def top_stores_using_tech(tech_name, limit \\ 50) do
    LS.UICache.fetch(:top_page, {:tech, tech_name, limit}, fn -> top_stores_using_tech_uncached(tech_name, limit) end)
  end

  defp top_stores_using_tech_uncached(tech_name, limit) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank
    FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND is_shopify = 1 AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  def top_stores_using_tech_in_country(tech_name, country_code, limit \\ 50) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank
    FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND is_shopify = 1
      AND country = '#{escape(country_code)}' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  # ── Directory / Hub pages ──

  def tech_directory do
    query("""
    SELECT arrayJoin(splitByString('|', http_tech)) AS tech, count() AS cnt
    FROM domains_fast WHERE http_tech != ''
    GROUP BY tech HAVING cnt >= 5 ORDER BY cnt DESC LIMIT 500
    """)
  end

  # arrayJoin over every non-empty http_tech is a full scan, and both /tech/:slug
  # and /compare/:slug need it on every request just to resolve their slug.
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
    query("""
    SELECT country, count() AS cnt FROM domains_fast
    WHERE is_shopify = 1 AND country != ''
    GROUP BY country
    HAVING cnt >= 10
    ORDER BY cnt DESC
    """)
  end

  # ── Sitemap ──

  def all_shopify_domains(limit \\ 49_000) do
    query("""
    SELECT domain FROM domains_fast
    WHERE is_shopify = 1 AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  def scan_rate_per_minute do
    case query("SELECT count() FROM domains_history WHERE enriched_at >= now() - INTERVAL 1 MINUTE") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def scan_rate_per_second do
    case query("SELECT count() / 60.0 FROM domains_history WHERE enriched_at >= now() - INTERVAL 1 MINUTE") do
      {:ok, [[rate]]} when is_number(rate) -> Float.round(rate / 1.0, 1)
      _ -> nil
    end
  end

  def stores_last_hour do
    case query("SELECT count() FROM domains_history WHERE enriched_at >= now() - INTERVAL 1 HOUR") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def shopify_stores_last_hour do
    # NB: `is_shopify` only exists on domains_fast (materialized on the MV
    # inner table) — on the raw domains_history log we must use the expression it
    # materializes. The previous version queried `is_shopify` here, got
    # UNKNOWN_IDENTIFIER on every call, and silently returned nil.
    case query("SELECT count() FROM domains_history WHERE enriched_at >= now() - INTERVAL 1 HOUR AND http_tech LIKE '%Shopify%'") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def all_tech_slugs do
    case tech_directory() do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [tech | _] -> tech end)}
      err -> err
    end
  end

  @doc """
  Tech names that at least `min` SHOPIFY stores actually use — the only techs
  the sitemap may emit /top/shopify-stores-using-* URLs for.

  The sitemap used to emit that URL for EVERY known tech, but the page 404s
  when the Shopify intersection is empty (Pendo, enterprise SaaS tools...), so
  the sitemap advertised 404s to Google. Same data-contract rule as the UI:
  never offer a link that matches no rows. `min` defaults to 3 so one
  misdetected store cannot resurrect a URL that will soon 404 again.
  """
  def shopify_tech_names(min \\ 3) do
    query("""
    SELECT tech, count() AS n FROM (
      SELECT arrayJoin(splitByChar('|', http_tech)) AS tech
      FROM domains_fast
      WHERE is_shopify = 1 AND http_title != '' AND http_tech != ''
    )
    WHERE tech != ''
    GROUP BY tech
    HAVING n >= #{max(1, min)}
    ORDER BY n DESC
    SETTINGS max_threads=2, max_bytes_before_external_group_by=1000000000
    """)
  end


  @doc """
  Latest observed changes for one domain (public store-page teaser).
  biz_signal is small and keyed (dataset-wide scans are cheap); LIMIT keeps it O(1)-ish.
  """
  def recent_signals(domain, limit \\ 5) do
    query("""
    SELECT kind, value, changed_at FROM biz_signal
    WHERE domain = '#{escape(domain)}'
    ORDER BY changed_at DESC LIMIT #{limit}
    """)
  end

  @doc "How many other businesses share this model+country — the store-page teaser hook."
  def count_similar(business_model, country) when business_model != "" do
    query("""
    SELECT count() FROM businesses
    WHERE business_model = '#{escape(business_model)}'
      AND inferred_country = '#{escape(country)}' AND is_junk = ''
    """)
  end

  def count_similar(_, _), do: {:ok, [[0]]}

  @doc """
  Named "businesses like this one" for the store-page similar block: same
  business model + country, best-ranked first. Returns
  `[[domain, title, tranco_rank, is_shopify], ...]`.

  The count-only teaser sent every visitor straight to a signup wall; showing
  the top few BY NAME (SimilarWeb's "similar sites" pattern) gives an
  accidental visitor somewhere to go next, and the gate moves to the tail of
  the list instead of its head. Cached 6h per (model, country) — the page is
  CDN-cached and the answer barely moves within a day.
  """
  @similar_stores_ttl :timer.hours(6)

  # Same revenue tier as the target — similarity that converts, per the
  # 2026-08-17 report: rank-ordered-globally showed icloud/nih.gov/cisco as
  # "SaaS like this" next to a seed-stage startup.
  @tier_brackets %{
    "<$1M" => ["<$1M"],
    "$1M-$10M" => ["$1M-$10M"],
    "$10M-$100M" => ["$10M-$100M", "$100M-$1B", "$1B+"],
    "$100M-$1B" => ["$10M-$100M", "$100M-$1B", "$1B+"],
    "$1B+" => ["$10M-$100M", "$100M-$1B", "$1B+"]
  }

  def similar_stores(business_model, country, exclude_domain, revenue, rank, limit \\ 6)

  def similar_stores(business_model, country, exclude_domain, revenue, rank, limit)
      when business_model != "" and country != "" do
    tier = Map.get(@tier_brackets, revenue, ["<$1M"])
    tier_sql = tier |> Enum.map(&"'#{escape(&1)}'") |> Enum.join(",")

    # Rank proximity: peers ranked BETTER than the target but nearest to it
    # (aspirational yet comparable). Unranked targets get recent same-tier
    # peers instead. Bucketed cache key keeps the 6h cache effective.
    {rank_where, order, bucket} =
      case rank do
        r when is_integer(r) and r > 0 ->
          # Coarse log-ish bands, NOT div(rank, 20_000). The fine bucket gave
          # every store page its own cache key — 71 distinct buckets among just
          # 129 cached entries — so this query, the single most expensive on the
          # site (148,603 CPU-seconds/day over 15,468 calls averaging 9.6s),
          # almost always missed. Rank 100,000 and 120,000 are not meaningfully
          # different neighbours; four bands are.
          band =
            cond do
              r <= 100_000 -> :top100k
              r <= 1_000_000 -> :top1m
              true -> :rest
            end

          {"AND tranco_rank > 0 AND tranco_rank <= #{r}", "ORDER BY tranco_rank DESC", band}

        _ ->
          {"", "ORDER BY as_of DESC", :unranked}
      end

    LS.LandingCache.cached({:similar_stores, business_model, country, tier, bucket}, @similar_stores_ttl, fn ->
      query("""
      SELECT domain, http_title, tranco_rank, is_shopify
      FROM businesses
      WHERE business_model = '#{escape(business_model)}'
        AND inferred_country = '#{escape(country)}'
        AND estimated_revenue IN (#{tier_sql})
        AND classification_confidence >= 0.5
        AND is_junk = '' AND http_title != ''
      #{rank_where}
      #{order}
      LIMIT #{limit + 4}
      """)
    end)
    |> case do
      {:ok, rows} ->
        rows
        |> Enum.reject(fn [d | _] -> d == exclude_domain end)
        |> Enum.uniq_by(fn [d | _] -> d end)
        |> Enum.take(limit)

      _ ->
        []
    end
  end

  def similar_stores(_, _, _, _, _, _), do: []

  # ── Trends: the biz_signal change feed as public, citable numbers ──
  #
  # biz_signal records tech_added / tech_removed / app_added / app_removed /
  # started_hiring per domain (emitted by the compactor below). Nobody else
  # publishes weekly adoption AND churn per technology, which makes these pages
  # the most AI-citable thing we can serve. Everything here is 6h-cached: the
  # numbers move daily, the pages are CDN-cached anyway, the master has 3 cores.

  @trend_ttl :timer.hours(6)

  @doc "Adds/drops for one tech: %{adds_7d, drops_7d, adds_30d, drops_30d}."
  def tech_trends(tech) do
    LS.LandingCache.cached({:tech_trends, tech}, @trend_ttl, fn ->
      query("""
      SELECT countIf(kind='tech_added'   AND changed_at >= now() - INTERVAL 7 DAY),
             countIf(kind='tech_removed' AND changed_at >= now() - INTERVAL 7 DAY),
             countIf(kind='tech_added'   AND changed_at >= now() - INTERVAL 30 DAY),
             countIf(kind='tech_removed' AND changed_at >= now() - INTERVAL 30 DAY)
      FROM biz_signal
      WHERE value = '#{escape(tech)}' AND kind IN ('tech_added','tech_removed')
      """)
    end)
    |> case do
      {:ok, [[a7, d7, a30, d30]]} -> %{adds_7d: a7, drops_7d: d7, adds_30d: a30, drops_30d: d30}
      _ -> nil
    end
  end

  @doc "Top movers by 30d adoption: [[tech, adds_30d, drops_30d], ...]."
  def tech_movers(limit \\ 25) do
    LS.LandingCache.cached({:tech_movers, limit}, @trend_ttl, fn ->
      query("""
      SELECT value, countIf(kind='tech_added') AS adds, countIf(kind='tech_removed') AS drops
      FROM biz_signal
      WHERE changed_at >= now() - INTERVAL 30 DAY AND kind IN ('tech_added','tech_removed')
      GROUP BY value HAVING adds >= 50
      ORDER BY adds DESC LIMIT #{limit}
      """)
    end)
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc "Most recent adopters of a tech: [[domain, changed_at], ...] — teaser rows."
  def recent_adopters(tech, limit \\ 6) do
    LS.LandingCache.cached({:recent_adopters, tech}, @trend_ttl, fn ->
      query("""
      SELECT domain, max(changed_at) AS at FROM biz_signal
      WHERE kind = 'tech_added' AND value = '#{escape(tech)}'
        AND changed_at >= now() - INTERVAL 30 DAY
      GROUP BY domain ORDER BY at DESC LIMIT #{limit}
      """)
    end)
    |> case do
      {:ok, rows} -> rows
      _ -> []
    end
  end

  @doc """
  Domains that dropped `from` and added `to` inside the window — observed
  switching, a number a vendor's competitive team cannot get anywhere else.
  Returns %{count, sample} (sample = up to 5 most recent domains).
  """
  def switchers(from, to, days \\ 90) do
    LS.LandingCache.cached({:switchers, from, to, days}, @trend_ttl, fn ->
      query("""
      SELECT domain, max(changed_at) AS at FROM biz_signal
      WHERE changed_at >= now() - INTERVAL #{days} DAY
        AND ((kind='tech_removed' AND value='#{escape(from)}')
          OR (kind='tech_added'  AND value='#{escape(to)}'))
      GROUP BY domain
      HAVING countIf(kind='tech_removed' AND value='#{escape(from)}') > 0
         AND countIf(kind='tech_added'  AND value='#{escape(to)}') > 0
      ORDER BY at DESC LIMIT 500
      """)
    end)
    |> case do
      {:ok, rows} -> %{count: length(rows), sample: rows |> Enum.take(5) |> Enum.map(&hd/1)}
      _ -> %{count: 0, sample: []}
    end
  end

  # ── Industry / business-model top pages ──

  @doc """
  Top businesses for an industry or business model, same row shape as the
  country tops so TopHTML's show template renders it unchanged.
  """
  def top_by_segment(kind, name, limit \\ 50) do
    where =
      case kind do
        :industry -> "industry = '#{escape(name)}'"
        :model -> "business_model = '#{escape(name)}'"
        # /top/shopify — a platform, not a model, so match the tech stack
        :tech -> "http_tech LIKE '%#{escape(name)}%'"
      end

    LS.LandingCache.cached({:top_segment, kind, name}, @trend_ttl, fn ->
      query("""
      SELECT domain, http_title, http_tech, inferred_country, tranco_rank
      FROM businesses
      WHERE is_junk = '' AND http_title != '' AND #{where}
      ORDER BY coalesce(tranco_rank, 99999999) ASC LIMIT #{limit}
      """)
    end)
  end

  @doc "Non-junk, titled business counts per industry/model — sitemap gating."
  def segment_counts(kind) do
    field = segment_field(kind)

    LS.LandingCache.cached({:segment_counts, kind}, @trend_ttl, fn ->
      query("""
      SELECT #{field}, count() FROM businesses
      WHERE is_junk = '' AND http_title != '' AND #{field} != ''
      GROUP BY #{field}
      """)
    end)
    |> case do
      {:ok, rows} -> Map.new(rows, fn [k, v] -> {k, v} end)
      _ -> %{}
    end
  end

  defp segment_field(:industry), do: "industry"
  defp segment_field(:model), do: "business_model"

  @doc """
  Shopify-store counts per (tech, country) for the given techs, in ONE scan —
  a per-tech loop would be N full scans of domains_fast on 3 cores. Returns
  %{{tech, country} => count}; feeds the /top/shopify-stores-using-X-in-CC
  sitemap section, thresholded by the caller.
  """
  def tech_country_matrix(techs) when is_list(techs) and techs != [] do
    LS.LandingCache.cached({:tech_country_matrix, Enum.sort(techs)}, @trend_ttl, fn ->
      cols =
        techs
        |> Enum.with_index()
        |> Enum.map_join(", ", fn {t, i} ->
          "countIf(http_tech LIKE '%#{escape(t)}%') AS t#{i}"
        end)

      query("""
      SELECT country, #{cols} FROM domains_fast
      WHERE is_shopify = 1 AND http_title != '' AND country != ''
      GROUP BY country
      """)
    end)
    |> case do
      {:ok, rows} ->
        for [country | counts] <- rows,
            {count, i} <- Enum.with_index(counts),
            reduce: %{} do
          acc -> Map.put(acc, {Enum.at(techs, i), country}, count)
        end

      _ ->
        %{}
    end
  end

  # ── biz_signal: observed business changes ──

  @doc """
  Emit change signals for the slice `[since, until)` by comparing the newest
  SUCCESSFUL crawl state in the slice against the current `businesses` row.

  Must run BEFORE `compact_businesses/2` for the same slice: the diff needs
  the OLD state, and compaction overwrites it. Failure here never blocks
  compaction — signals are derived data.

  Signal semantics (the part that keeps them honest):
    * only crawls with http_status 200-399 AND non-empty tech count — a
      failed or blind crawl is a fact about the crawl, not the business;
    * domains must already exist in `businesses` with non-empty tech —
      a first crawl "adds" everything and means nothing;
    * biz_signal is a ReplacingMergeTree on the full row, so a retried
      slice re-emitting identical signals dedups instead of duplicating.
  """
  def record_signals(since_unix, until_unix) do
    window = "enriched_at >= toDateTime(#{since_unix}) AND enriched_at < toDateTime(#{until_unix})"

    new_state = """
    SELECT domain,
           max(enriched_at) AS at,
           argMax(http_tech, enriched_at) AS new_tech,
           argMax(http_apps, enriched_at) AS new_apps
    FROM domains_history
    WHERE #{window} AND http_status BETWEEN 200 AND 399 AND http_tech != ''
    GROUP BY domain
    """

    tech_sql = """
    INSERT INTO biz_signal (kind, value, domain, changed_at)
    SELECT sig.1 AS kind, sig.2 AS value, n.domain, n.at
    FROM (#{new_state}) n
    INNER JOIN (
      SELECT domain, http_tech, http_apps FROM businesses
      WHERE http_tech != '' AND domain IN (
        SELECT domain FROM domains_history WHERE #{window}
      )
    ) b ON n.domain = b.domain
    ARRAY JOIN arrayConcat(
      arrayMap(x -> ('tech_added', x),
        arrayFilter(x -> x != '' AND NOT has(splitByChar('|', b.http_tech), x), splitByChar('|', n.new_tech))),
      arrayMap(x -> ('tech_removed', x),
        arrayFilter(x -> x != '' AND NOT has(splitByChar('|', n.new_tech), x), splitByChar('|', b.http_tech))),
      arrayMap(x -> ('app_added', x),
        arrayFilter(x -> x != '' AND NOT has(splitByChar('|', b.http_apps), x), splitByChar('|', n.new_apps))),
      arrayMap(x -> ('app_removed', x),
        arrayFilter(x -> x != '' AND NOT has(splitByChar('|', n.new_apps), x), splitByChar('|', b.http_apps)))
    ) AS sig
    SETTINGS join_use_nulls = 0, max_threads = 2
    """

    hiring_sql = """
    INSERT INTO biz_signal (kind, value, domain, changed_at)
    SELECT if(new_jobs > 0, 'started_hiring', 'stopped_hiring') AS kind,
           toString(new_jobs) AS value, n.domain, n.at
    FROM (
      SELECT domain, max(enriched_at) AS at,
             argMaxIf(job_count, enriched_at, job_count IS NOT NULL) AS new_jobs
      FROM biz_enrichment_log
      WHERE #{window} AND render_engine != 'failed'
      GROUP BY domain
      HAVING new_jobs IS NOT NULL
    ) n
    INNER JOIN (
      SELECT domain, job_count FROM businesses
      WHERE domain IN (SELECT domain FROM biz_enrichment_log WHERE #{window})
    ) b ON n.domain = b.domain
    WHERE (coalesce(b.job_count, 0) = 0 AND new_jobs > 0)
       OR (coalesce(b.job_count, 0) > 0 AND new_jobs = 0)
    SETTINGS join_use_nulls = 1, max_threads = 2
    """

    with {:ok, _} <- query_raw(tech_sql, 120_000, background: true),
         {:ok, _} <- query_raw(hiring_sql, 120_000, background: true) do
      :ok
    end
  end

  @doc """
  Backfill one hash-shard of biz_signal from crawl history (window function
  over consecutive successful crawls per domain). Same 256-shard pattern as
  the country backfill; run only when the box is otherwise quiet.
  """
  def backfill_signals_shard(shard, total) do
    guard = "cityHash64(domain) % #{total} = #{shard}"

    sql = """
    INSERT INTO biz_signal (kind, value, domain, changed_at)
    SELECT sig.1, sig.2, domain, at FROM (
      SELECT domain, enriched_at AS at,
             splitByChar('|', http_tech) AS cur_t,
             splitByChar('|', lagInFrame(http_tech, 1, '') OVER w) AS prev_t,
             splitByChar('|', http_apps) AS cur_a,
             splitByChar('|', lagInFrame(http_apps, 1, '') OVER w) AS prev_a,
             lagInFrame(http_tech, 1, '') OVER w AS prev_raw
      FROM domains_history
      WHERE #{guard} AND http_status BETWEEN 200 AND 399 AND http_tech != ''
        AND domain IN (SELECT domain FROM businesses WHERE #{guard})
      WINDOW w AS (PARTITION BY domain ORDER BY enriched_at ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING)
    )
    ARRAY JOIN arrayConcat(
      arrayMap(x -> ('tech_added', x),   arrayFilter(x -> x != '' AND NOT has(prev_t, x), cur_t)),
      arrayMap(x -> ('tech_removed', x), arrayFilter(x -> x != '' AND NOT has(cur_t, x), prev_t)),
      arrayMap(x -> ('app_added', x),    arrayFilter(x -> x != '' AND NOT has(prev_a, x), cur_a)),
      arrayMap(x -> ('app_removed', x),  arrayFilter(x -> x != '' AND NOT has(cur_a, x), prev_a))
    ) AS sig
    WHERE prev_raw != ''
    SETTINGS max_threads = 2, max_bytes_before_external_group_by = 1000000000
    """

    query_raw(sql, 300_000)
  end

  # ── Engagement digests ──

  @doc """
  Count businesses matching a saved dashboard search, optionally only those
  FIRST SEEN in the last `:first_seen_days` — the "new since your last visit"
  number the weekly digest is built around. Filters are the same map the
  explorer records into the audit trail, so the digest counts exactly what
  the user's search would show today.
  """
  def count_businesses_for_digest(filters) when is_map(filters) do
    {days, rest} = Map.pop(filters, :first_seen_days)
    base = LS.Explorer.count_sql(rest)

    sql =
      cond do
        is_nil(days) -> base
        String.contains?(base, "WHERE") -> base <> " AND first_seen > now() - INTERVAL #{days} DAY"
        true -> base <> " WHERE first_seen > now() - INTERVAL #{days} DAY"
      end

    case query_raw(sql) do
      {:ok, [[n]]} -> {:ok, to_count(n)}
      err -> err
    end
  end

  @doc "Added/removed counts for one tech over `days` — the digest's signal line."
  def signal_counts_for(tech, days) do
    sql = """
    SELECT countIf(kind = 'tech_added' OR kind = 'app_added') AS added,
           countIf(kind = 'tech_removed' OR kind = 'app_removed') AS removed
    FROM biz_signal
    WHERE value = '#{escape(tech)}' AND changed_at > now() - INTERVAL #{days} DAY
    """

    case query_raw(sql) do
      {:ok, [[a, r]]} -> {:ok, to_count(a), to_count(r)}
      err -> err
    end
  end

  @doc """
  Shopify stores discovered in the last `days` that already carry a contact
  address. This is the number the welcome email quotes, so it must be true and
  it must be cheap: the caller caches it, and it is a single scan of
  `businesses` (~0.3s) rather than anything per-recipient.
  """
  def fresh_contactable_shopify(days \\ 7) do
    sql = """
    SELECT count() FROM businesses
    WHERE positionCaseInsensitive(http_tech, 'shopify') > 0
      AND http_emails != ''
      AND first_seen > now() - INTERVAL #{days} DAY
    SETTINGS max_threads = 2
    """

    case query_raw(sql) do
      {:ok, [[n]]} -> {:ok, to_count(n)}
      err -> err
    end
  end

  # ── Recrawl scheduler ──

  @doc """
  Fetch domains that need re-crawling based on tiered freshness.
  Digital businesses (Ecommerce, SaaS, Tool, Marketplace, Agency) → stale after `weekly_days`.
  Everything else → stale after `monthly_days`.
  Returns {:ok, [domain, ...]} or {:error, reason}.

  A domain qualifies when it was ever crawled (`http_status`) *or* is known
  DNS-alive (`dns_a`). The old `http_status IS NOT NULL`-only filter
  permanently orphaned any domain whose newest row was hollow — the 2026-07
  h1 resolver incident produced ~45M such rows, hiding its victims from the
  very scheduler that could heal them.

  `enriched_at ASC` as tie-break makes selection among equal-rank (mostly
  unranked) domains oldest-first, so recrawl is eventually-complete instead
  of arbitrary — unranked domains could otherwise starve indefinitely.
  """
  def stale_domains(weekly_days, monthly_days, limit \\ 5000) do
    # Digital business models that get weekly crawling
    digital_bms = "'Ecommerce','SaaS','Tool','Marketplace','Agency'"

    sql = """
    SELECT domain FROM domains_current FINAL
    WHERE (
      (business_model IN (#{digital_bms}) AND enriched_at < now() - INTERVAL #{weekly_days} DAY)
      OR
      (business_model NOT IN (#{digital_bms}) AND enriched_at < now() - INTERVAL #{monthly_days} DAY)
    )
    AND (http_status IS NOT NULL OR dns_a != '')
    ORDER BY tranco_rank ASC NULLS LAST, enriched_at ASC
    LIMIT #{limit}
    """

    case query(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [d] -> d end)}
      err -> err
    end
  end

  # ── Pipeline 2: enrichment queue + compaction ──

  @doc """
  SQL predicate selecting ONE enrichment lane. Exposed so a test can assert the
  two lanes stay disjoint: if they ever overlap, the browser lane is back to
  competing with seven million reachable businesses and starves to zero.
  """
  @spec enrichment_lane_filter(keyword()) :: String.t()
  def enrichment_lane_filter(opts) do
    if Keyword.get(opts, :browser_only, false) do
      "(b.last_http_blocked != '' OR b.last_http_status IN (401, 403))"
    else
      "b.crawlable AND b.last_http_blocked = '' AND " <>
        "(b.last_http_status IS NULL OR b.last_http_status NOT IN (401, 403))"
    end
  end

  @doc """
  Domains due for depth enrichment, newest-value-first by commercial value.

  Picks businesses whose `biz_enrichment` is missing or stale, preferring the
  ones a customer is most likely to filter on (ranked, then Shopify/SaaS).
  Returns the context the enrichment agent needs so it does not have to
  re-query per domain: the recorded `http_pages`, the detected tech, and
  whether the site previously blocked us (which is what makes it a browser
  job rather than a plain HTTP one).
  """
  @spec businesses_needing_enrichment(pos_integer(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def businesses_needing_enrichment(limit, opts \\ []) do
    # The two lanes are selected SEPARATELY and never overlap, because they
    # compete on incomparable terms. A WAF-walled business has no emails and
    # weak classification precisely BECAUSE discovery could not read it, so in
    # a single value-ordered query it sorts below seven million reachable
    # businesses and is never reached: the browser bucket sat empty while
    # ~900K blocked businesses waited and every camoufox on the fleet idled.
    # Giving the browser lane its own budget is what keeps the renders fed.

    lane_filter = enrichment_lane_filter(opts)

    sql = """
    SELECT b.domain, b.http_pages, b.http_tech, b.last_http_blocked, b.last_http_status,
      -- inferred_country is load-bearing for phone extraction, not decoration:
      -- a number printed "030 12345678" cannot be normalised to E.164 without
      -- it, and guessing a country prefix mints a number that dials a real
      -- stranger. With the country known every phone found on the German
      -- sample normalised; without it, 55% did (2026-08-27).
      b.inferred_country,
      -- Depth tier from signals we already hold. FULL treatment for businesses
      -- worth the extra pages: any rank, any email, a mail server plus solid
      -- classification, or a commerce fingerprint (catalog data pays). The
      -- rest get the LIGHT pass — homepage + contact only, no browser
      -- fallback — at roughly a third of the cost. Nothing is excluded;
      -- the tail is just crawled proportionally to its value.
      if(b.tranco_rank IS NOT NULL OR b.majestic_rank IS NOT NULL
         OR b.http_emails != ''
         OR (b.dns_mx != '' AND b.classification_confidence >= 0.6)
         OR positionCaseInsensitive(concat(b.http_tech, b.http_apps), 'shopify') > 0,
         'full', 'light') AS tier
    FROM businesses b
    -- Semi-join, not LEFT JOIN: identical result set (measured 2026-08-24 —
    # 256,992 vs 257,158 distinct domains, the delta is concurrent writes) but
    -- 8.2s instead of 13.1s, because a JOIN costs ~9x a single-table scan here.
    -- NOT the folded depth-enrichment timestamp on businesses, tempting as it
    -- looks: that column is NULL for
    -- ~2.3M domains that biz_enrichment shows ARE enriched (the compactor only
    -- folds non-failed render rows), so using it would re-crawl 2.3M sites we
    -- already have — wasteful and impolite.
    WHERE #{lane_filter}
      AND b.dns_alive
      AND b.domain NOT IN (SELECT domain FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 30 DAY)
      -- A domain that rate-limited us is not worth retrying on the ordinary
      -- cadence: it asked for patience, and re-asking daily is how a source
      -- IP earns a permanent block. Give it a fortnight.
      AND (b.last_http_status != 429 OR b.as_of < now() - INTERVAL 14 DAY)
    -- Value-first ordering, not Tranco-only: only 5.4% of businesses carry a
    -- Tranco rank (storeradar-shaped SMBs carry none), so pure tranco order
    -- left 94% of the table in arbitrary order. Majestic (backlinks) is an
    -- independent second rank, scaled 1M->4.2M; unranked businesses are then
    -- ordered by commercial signals instead of nothing.
    ORDER BY
      least(coalesce(b.tranco_rank, 99999999), coalesce(b.majestic_rank * 4, 99999999)) ASC,
      (b.http_emails != '') + (b.dns_mx != '') + (b.classification_confidence >= 0.6) DESC
    -- businesses is read WITHOUT FINAL (a FINAL sort-scan of 6.7M rows every
    -- 5 minutes is not worth it), so every compactor pass contributes another
    -- version row per changed domain. Without this, each version became its
    -- own queue entry — top domains appeared up to 9x and ~80% of enrichment
    -- capacity was spent re-enriching the same businesses (2026-07-31).
    LIMIT 1 BY b.domain
    LIMIT #{limit}
    """

    # 90s, not the 25s default: this is a background refill on a 5-minute timer,
    # and on a loaded box the 25s budget expired before the scan finished. The
    # queue then got NOTHING, so the enrichment-only nodes sat idle with a
    # 257K backlog waiting (2026-08-24).
    case query_raw(sql, 90_000) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [d, pages, tech, blocked, status, country, tier] ->
           %{domain: d, http_pages: pages, http_tech: tech,
             http_blocked: blocked, last_http_status: status,
             inferred_country: country, tier: tier}
         end)}

      err ->
        err
    end
  end

  @doc """
  Refresh `businesses` rows for domains touched in `[since_unix, until_unix)`.

  Coalesces "last non-empty per signal unit" from `domains_history` and folds
  in `biz_enrichment`. Insert-only: `businesses` is a ReplacingMergeTree keyed
  on domain, so a fresh row supersedes the old one at merge time.
  Returns `{:ok, rows_written}`.

  `until_unix` exists because of the 2026-08-05 death spiral: the window was
  open-ended ("everything since the last success"), so once one pass timed
  out, every retry faced a strictly larger batch and compaction never
  succeeded again — 50 straight failures while `businesses` went 19h stale.
  A bounded slice makes each attempt the same size no matter how long the
  compactor has been down.
  """
  @spec compact_businesses(integer(), integer() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def compact_businesses(since_unix, until_unix \\ nil) do
    with {:ok, _} <- query_raw(compact_sql(since_unix, until_unix), 300_000, background: true),
         {:ok, [[n]]} <- query("SELECT count() FROM businesses WHERE as_of >= toDateTime(#{since_unix})") do
      # ClickHouse JSON quotes UInt64 by default, so count() can arrive as a
      # string — which would crash the compactor's stats arithmetic.
      {:ok, to_count(n)}
    else
      {:ok, _} -> {:ok, 0}
      err -> err
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

  @doc "Full `businesses` rebuild — repair tool. See `LS.Cluster.Compactor`."
  def rebuild_businesses_full, do: query_raw(compact_sql(0), 30 * 60_000, background: true)

  @doc """
  Rebuild one hash-shard of `businesses` — the memory-safe backfill unit.

  A full rebuild in one query no longer fits the shared box (the unscoped
  joins are the same memory bomb the compactor hit on 2026-08-05). Sharding
  by domain hash keeps each pass slice-sized; 256 shards of ~37K domains run
  ~1-2 min each and the whole table backfills in hours without touching the
  6.5G cap.
  """
  def compact_shard(shard, total_shards) do
    query_raw(compact_sql_shard(shard, total_shards), 300_000, background: true)
  end

  defp compact_sql_shard(shard, total) do
    # The shard is a set of DOMAINS, not a raw hash predicate on every table.
    # domains_history is sorted by (domain, enriched_at), so `domain IN (set)`
    # granule-prunes the read; a bare cityHash64(domain) predicate forced a
    # FULL scan of the 100M-row table per shard — 256 full scans, which is
    # why the first backfill attempt sat silent for 20 minutes doing nothing
    # visible. Membership in `businesses` also bounds the set to real
    # businesses (9.6M) rather than every domain ever seen.
    set = "SELECT domain FROM businesses WHERE cityHash64(domain) % #{total} = #{shard}"
    guard = "domain IN (#{set})"

    # Every table read carries the guard — one unsharded side is the whole
    # memory problem back.
    compact_sql(0)
    |> String.replace(
      "FROM domains_history)",
      "FROM domains_history WHERE #{guard})"
    )
    |> String.replace(
      "FROM biz_enrichment_log WHERE render_engine != 'failed'",
      "FROM biz_enrichment_log WHERE #{guard} AND render_engine != 'failed'"
    )
    |> String.replace("FROM biz_pricing GROUP BY", "FROM biz_pricing WHERE #{guard} GROUP BY")
    |> String.replace("FROM biz_news GROUP BY", "FROM biz_news WHERE #{guard} GROUP BY")
    |> String.replace("FROM verified_facts\n", "FROM verified_facts WHERE #{guard}\n")
  end

  # Pipeline 3's contribution to a `businesses` row: one verified revenue and
  # one verified employees value per domain, chosen by source PRECEDENCE
  # (audited filings beat registries beat crowd data), never by recency —
  # a fresher Wikidata edit must not displace a 10-K. Values arrive as the
  # normalised strings `verified_facts` stores (USD integer / head-count /
  # bracket label) and leave as the estimator's bracket labels, so
  # `verified_revenue` filters and renders exactly like `estimated_revenue`.
  # `SELECT ... FINAL` on a slice-sized domain set is cheap; unscoped it is
  # what the sharded rebuild guards (see compact_sql_shard/2).
  @doc false
  def verified_sql(join_scope) do
    rev = Enum.with_index(LS.Verification.revenue_precedence(), 1)
    emp = Enum.with_index(LS.Verification.employees_precedence(), 1)
    prio = fn pairs -> Enum.map_join(pairs, ", ", fn {src, i} -> "source = '#{src}', #{i}" end) end

    """
    SELECT domain,
      argMinIf(rev_bracket, rev_prio, fact = 'revenue_usd' AND rev_bracket != '') AS verified_revenue,
      argMinIf(source, rev_prio, fact = 'revenue_usd' AND rev_bracket != '') AS verified_revenue_source,
      argMinIf(emp_bracket, emp_prio, fact IN ('employees', 'employees_band') AND emp_bracket != '') AS verified_employees,
      argMinIf(source, emp_prio, fact IN ('employees', 'employees_band') AND emp_bracket != '') AS verified_employees_source,
      argMaxIf(value, fetched_at, fact = 'mission') AS mission_summary
    FROM (
      SELECT domain, fact, source, value, fetched_at,
        multiIf(#{prio.(rev)}, 99) AS rev_prio,
        multiIf(#{prio.(emp)}, 99) AS emp_prio,
        multiIf(fact != 'revenue_usd', '',
                toFloat64OrZero(value) < 1e6, '<$1M', toFloat64OrZero(value) < 1e7, '$1M-$10M',
                toFloat64OrZero(value) < 1e8, '$10M-$100M', toFloat64OrZero(value) < 1e9, '$100M-$1B', '$1B+') AS rev_bracket,
        multiIf(fact = 'employees_band', value,
                fact != 'employees' OR toUInt32OrZero(value) = 0, '',
                toUInt32OrZero(value) <= 10, '1-10', toUInt32OrZero(value) <= 50, '11-50',
                toUInt32OrZero(value) <= 500, '51-500', toUInt32OrZero(value) <= 5000, '501-5000', '5001+') AS emp_bracket
      FROM (
        /* newest value per (domain, fact, source): facts are keyed on their
           value so a new fiscal year sits next to the old one as history.
           LIMIT 1 BY, not GROUP BY+argMax — an inner max(fetched_at) that the
           outer argMaxIf(value, fetched_at, ...) also reads is a nested
           aggregate ClickHouse rejects (Code 184), which silently failed
           EVERY compaction pass and froze `businesses` for 12h on 2026-08-19. */
        SELECT domain, fact, source, value, fetched_at
        FROM verified_facts#{join_scope}
        ORDER BY fetched_at DESC
        LIMIT 1 BY domain, fact, source
      )
    )
    GROUP BY domain
    """
  end

  # One statement, two sources. `argMaxIf(col, ts, <unit populated>)` is the
  # anti-erasure rule: a later empty row cannot overwrite an earlier good value.
  @doc false
  def compact_sql_for_test(since_unix), do: compact_sql(since_unix)

  defp compact_sql(since_unix, until_unix \\ nil) do
    upper = if until_unix, do: " AND enriched_at < toDateTime(#{until_unix})", else: ""

    # The same bounded domain set scopes BOTH sides of every join. The
    # 2026-08-05 MEMORY_LIMIT_EXCEEDED failures came from the join sides
    # being unscoped: `SELECT * FROM biz_enrichment FINAL` materialised the
    # whole table (2.6M wide rows) as a hash table before joining — a cost
    # that grew with the product until it crossed the shared box's 6.5G cap.
    # Scoped, every join is ~slice-sized (10K rows) and stays that way at
    # 10M businesses or 100M.
    domain_set =
      """
      SELECT domain FROM domains_history WHERE enriched_at >= toDateTime(#{since_unix})#{upper}
      UNION DISTINCT
      SELECT domain FROM biz_enrichment WHERE enriched_at >= toDateTime(#{since_unix})#{upper}
      UNION DISTINCT
      SELECT domain FROM verified_facts WHERE fetched_at >= toDateTime(#{since_unix})#{String.replace(upper, "enriched_at", "fetched_at")}
      """

    scope = if since_unix > 0, do: "WHERE s_domain IN (#{domain_set})", else: ""
    join_scope = if since_unix > 0, do: " WHERE domain IN (#{domain_set})", else: ""

    # The depth side reads only SUCCESSFUL enrichment rows. Without this, the
    # newest row wins even when it is a failed attempt: a business enriched
    # fully in July whose August recrawl hits a WAF would have its catalogue,
    # SEO and jobs blanked by an empty "failed" row. Found 2026-08-06, three
    # weeks before the first 30-day re-enrichment wave would have made it
    # real at ~30% of all recrawls. A failed attempt is a fact about the
    # CRAWL, not about the business — it must never erase what a successful
    # crawl proved.
    depth_scope =
      if since_unix > 0 do
        "WHERE render_engine != 'failed' AND domain IN (#{domain_set})"
      else
        "WHERE render_engine != 'failed'"
      end

    """
    INSERT INTO businesses (domain, first_seen, as_of, last_verified_at, last_worker, crawlable, last_http_status, last_http_error, last_http_blocked, dns_alive, ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains, dns_a, dns_aaaa, dns_mx, dns_txt, dns_cname, http_status, http_response_time, http_blocked, http_content_type, http_tech, http_apps, http_language, http_title, http_meta_description, http_pages, http_emails, http_h1, business_model, industry, classification_confidence, http_schema_type, http_og_type, bgp_ip, bgp_asn_number, bgp_asn_org, bgp_asn_country, bgp_asn_prefix, inferred_country, rdap_domain_created_at, rdap_domain_expires_at, rdap_domain_updated_at, rdap_registrar, rdap_registrar_iana_id, rdap_nameservers, rdap_status, tranco_rank, majestic_rank, majestic_ref_subnets, is_disposable_email, is_junk, estimated_revenue, estimated_employees, revenue_confidence, revenue_evidence, product_count, price_min, price_avg, price_max, new_products_30d, last_product_at, oos_ratio, discount_depth, vendor_count, catalog_age_days, product_types, job_count, ats_platform, job_departments, job_locations, seo_score, seo_issues, seo_word_count, seo_alt_ratio, perf_lcp_ms, perf_cls, perf_ttfb_ms, render_engine, depth_enriched_at, about_text, mission, hq_location, job_locations_top, positions_overview, pricing_points, news_count, last_funding_usd, verified_revenue, verified_revenue_source, verified_employees, verified_employees_source, mission_summary)
    SELECT
      h.domain AS domain,
      h.first_seen, h.as_of, h.last_verified_at, h.last_worker, h.crawlable,
      h.last_http_status, h.last_http_error,
      -- `last_http_blocked` means "outstanding: nothing has reached this site
      -- since the block". A camoufox render that succeeded AFTER the block was
      -- recorded is a success, so the flag clears — otherwise a WAF that
      -- rejects plain HTTP keeps a business marked blocked forever even though
      -- the browser lane reads it fine. (s.* are NULL when no enrichment row
      -- exists — join_use_nulls — so the condition is false and h wins.)
      if(s.render_engine = 'camoufox' AND s.enriched_at_newest > h._blk_at,
         '', h.last_http_blocked) AS last_http_blocked,
      h.dns_alive,
      h.ctl_tld, h.ctl_issuer, h.ctl_subdomain_count, h.ctl_subdomains,
      h.dns_a, h.dns_aaaa, h.dns_mx, h.dns_txt, h.dns_cname,
      h.http_status, h.http_response_time, h.http_blocked, h.http_content_type,
      h.http_tech, h.http_apps, h.http_language, h.http_title,
      h.http_meta_description, h.http_pages, h.http_emails, h.http_h1,
      h.business_model, h.industry, h.classification_confidence,
      h.http_schema_type, h.http_og_type,
      h.bgp_ip, h.bgp_asn_number, h.bgp_asn_org, h.bgp_asn_country, h.bgp_asn_prefix,
      /* Recomputed from the surviving signals rather than copied from
         history: the stored value was fabricated for CDN-fronted English
         .coms (en->US default, Shopify-ASN->CA), which is how India lost
         39K stores to the US bucket. Recomputing here is also what lets a
         rules fix backfill 9.6M rows without recrawling anything. */
      #{LS.CountryInferrer.sql_expr("h.ctl_tld", "h.http_language", "h.bgp_asn_country", "h.bgp_asn_org")} AS inferred_country,
      h.rdap_domain_created_at, h.rdap_domain_expires_at, h.rdap_domain_updated_at,
      h.rdap_registrar, h.rdap_registrar_iana_id, h.rdap_nameservers, h.rdap_status,
      h.tranco_rank, h.majestic_rank, h.majestic_ref_subnets,
      h.is_disposable_email, h.is_junk,
      h.estimated_revenue, h.estimated_employees, h.revenue_confidence, h.revenue_evidence,
      s.product_count, s.price_min, s.price_avg, s.price_max, s.new_products_30d,
      s.last_product_at, s.oos_ratio, s.discount_depth, s.vendor_count,
      s.catalog_age_days, s.product_types,
      s.job_count, s.ats_platform, s.job_departments, s.job_locations,
      s.seo_score, s.seo_issues, s.seo_word_count, s.seo_alt_ratio,
      s.perf_lcp_ms, s.perf_cls, s.perf_ttfb_ms,
      s.render_engine, s.enriched_at_newest AS depth_enriched_at,
      s.about_text, s.mission, s.hq_location, s.job_locations_top, s.positions_overview,
      p.pricing_points, n.news_count, n.last_funding_usd,
      v.verified_revenue, v.verified_revenue_source, v.verified_employees, v.verified_employees_source, v.mission_summary
    FROM (
      SELECT s_domain AS domain,
        min(s_enriched_at) AS first_seen,
        max(s_enriched_at) AS as_of,
        maxIf(s_enriched_at, s_http_status BETWEEN 200 AND 399) AS last_verified_at,
        argMax(s_worker, s_enriched_at) AS last_worker,
        max(s_http_status BETWEEN 200 AND 399) AS crawlable,
        argMaxIf(s_http_status, s_enriched_at, s_http_status IS NOT NULL) AS last_http_status,
        maxIf(s_enriched_at, s_http_error != '') AS _err_at,
        if(_err_at > last_verified_at,
           argMaxIf(s_http_error, s_enriched_at, s_http_error != ''), '') AS last_http_error,
        maxIf(s_enriched_at, s_http_blocked != '') AS _blk_at,
        if(_blk_at > last_verified_at,
           argMaxIf(s_http_blocked, s_enriched_at, s_http_blocked != ''), '') AS last_http_blocked,
        argMax(s_dns_a != '' OR s_dns_cname != '', s_enriched_at) AS dns_alive,
        argMaxIf(s_http_status, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_status,
        argMaxIf(s_http_response_time, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_response_time,
        argMaxIf(s_http_blocked, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_blocked,
        argMaxIf(s_http_content_type, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_content_type,
        argMaxIf(s_http_tech, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_tech,
        argMaxIf(s_http_apps, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_apps,
        argMaxIf(s_http_language, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_language,
        argMaxIf(s_http_title, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_title,
        argMaxIf(s_http_meta_description, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_meta_description,
        argMaxIf(s_http_pages, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_pages,
        argMaxIf(s_http_h1, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_h1,
        argMaxIf(s_http_schema_type, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_schema_type,
        argMaxIf(s_http_og_type, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_og_type,
        argMaxIf(s_business_model, s_enriched_at, s_business_model != '') AS business_model,
        argMaxIf(s_industry, s_enriched_at, s_business_model != '') AS industry,
        argMaxIf(s_classification_confidence, s_enriched_at, s_business_model != '') AS classification_confidence,
        argMaxIf(s_bgp_ip, s_enriched_at, s_bgp_asn_number != '') AS bgp_ip,
        argMaxIf(s_bgp_asn_number, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_number,
        argMaxIf(s_bgp_asn_org, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_org,
        argMaxIf(s_bgp_asn_country, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_country,
        argMaxIf(s_bgp_asn_prefix, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_prefix,
        argMaxIf(s_rdap_domain_created_at, s_enriched_at, s_rdap_registrar != '') AS rdap_domain_created_at,
        argMaxIf(s_rdap_domain_expires_at, s_enriched_at, s_rdap_registrar != '') AS rdap_domain_expires_at,
        argMaxIf(s_rdap_domain_updated_at, s_enriched_at, s_rdap_registrar != '') AS rdap_domain_updated_at,
        argMaxIf(s_rdap_registrar, s_enriched_at, s_rdap_registrar != '') AS rdap_registrar,
        argMaxIf(s_rdap_registrar_iana_id, s_enriched_at, s_rdap_registrar != '') AS rdap_registrar_iana_id,
        argMaxIf(s_rdap_nameservers, s_enriched_at, s_rdap_registrar != '') AS rdap_nameservers,
        argMaxIf(s_rdap_status, s_enriched_at, s_rdap_registrar != '') AS rdap_status,
        argMaxIf(s_ctl_tld, s_enriched_at, s_ctl_issuer != '') AS ctl_tld,
        argMaxIf(s_ctl_issuer, s_enriched_at, s_ctl_issuer != '') AS ctl_issuer,
        argMaxIf(s_ctl_subdomain_count, s_enriched_at, s_ctl_issuer != '') AS ctl_subdomain_count,
        argMaxIf(s_ctl_subdomains, s_enriched_at, s_ctl_issuer != '') AS ctl_subdomains,
        argMaxIf(s_estimated_revenue, s_enriched_at, s_estimated_revenue != '') AS estimated_revenue,
        argMaxIf(s_estimated_employees, s_enriched_at, s_estimated_revenue != '') AS estimated_employees,
        argMaxIf(s_revenue_confidence, s_enriched_at, s_estimated_revenue != '') AS revenue_confidence,
        argMaxIf(s_revenue_evidence, s_enriched_at, s_estimated_revenue != '') AS revenue_evidence,
        argMaxIf(s_dns_a, s_enriched_at, s_dns_a != '') AS dns_a,
        argMaxIf(s_dns_aaaa, s_enriched_at, s_dns_aaaa != '') AS dns_aaaa,
        argMaxIf(s_dns_mx, s_enriched_at, s_dns_mx != '') AS dns_mx,
        argMaxIf(s_dns_txt, s_enriched_at, s_dns_txt != '') AS dns_txt,
        argMaxIf(s_dns_cname, s_enriched_at, s_dns_cname != '') AS dns_cname,
        argMaxIf(s_inferred_country, s_enriched_at, s_inferred_country != '') AS inferred_country,
        argMaxIf(s_http_emails, s_enriched_at, s_http_emails != '') AS http_emails,
        argMaxIf(s_tranco_rank, s_enriched_at, s_tranco_rank IS NOT NULL) AS tranco_rank,
        argMaxIf(s_majestic_rank, s_enriched_at, s_majestic_rank IS NOT NULL) AS majestic_rank,
        argMaxIf(s_majestic_ref_subnets, s_enriched_at, s_majestic_ref_subnets IS NOT NULL) AS majestic_ref_subnets,
        if(max(s_is_malware = 'true'), 'true', '') AS is_malware,
        if(max(s_is_phishing = 'true'), 'true', '') AS is_phishing,
        if(max(s_is_disposable_email = 'true'), 'true', '') AS is_disposable_email,
        -- Junk follows the NEWEST successful fetch, unlike the sticky flags
        -- above: a parked domain that comes back to life must clear the flag,
        -- and a real site that dies into a parking page must gain it.
        argMaxIf(s_is_junk, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS is_junk
      FROM (SELECT enriched_at AS s_enriched_at, worker AS s_worker, domain AS s_domain, ctl_tld AS s_ctl_tld, ctl_issuer AS s_ctl_issuer, ctl_subdomain_count AS s_ctl_subdomain_count, ctl_subdomains AS s_ctl_subdomains, dns_a AS s_dns_a, dns_aaaa AS s_dns_aaaa, dns_mx AS s_dns_mx, dns_txt AS s_dns_txt, dns_cname AS s_dns_cname, http_status AS s_http_status, http_response_time AS s_http_response_time, http_blocked AS s_http_blocked, http_content_type AS s_http_content_type, http_tech AS s_http_tech, http_apps AS s_http_apps, http_language AS s_http_language, http_title AS s_http_title, http_meta_description AS s_http_meta_description, http_pages AS s_http_pages, http_emails AS s_http_emails, http_error AS s_http_error, http_h1 AS s_http_h1, business_model AS s_business_model, industry AS s_industry, classification_confidence AS s_classification_confidence, http_schema_type AS s_http_schema_type, http_og_type AS s_http_og_type, bgp_ip AS s_bgp_ip, bgp_asn_number AS s_bgp_asn_number, bgp_asn_org AS s_bgp_asn_org, bgp_asn_country AS s_bgp_asn_country, bgp_asn_prefix AS s_bgp_asn_prefix, inferred_country AS s_inferred_country, rdap_domain_created_at AS s_rdap_domain_created_at, rdap_domain_expires_at AS s_rdap_domain_expires_at, rdap_domain_updated_at AS s_rdap_domain_updated_at, rdap_registrar AS s_rdap_registrar, rdap_registrar_iana_id AS s_rdap_registrar_iana_id, rdap_nameservers AS s_rdap_nameservers, rdap_status AS s_rdap_status, tranco_rank AS s_tranco_rank, majestic_rank AS s_majestic_rank, majestic_ref_subnets AS s_majestic_ref_subnets, is_malware AS s_is_malware, is_phishing AS s_is_phishing, is_disposable_email AS s_is_disposable_email, is_junk AS s_is_junk, estimated_revenue AS s_estimated_revenue, estimated_employees AS s_estimated_employees, revenue_confidence AS s_revenue_confidence, revenue_evidence AS s_revenue_evidence FROM domains_history)
      #{scope}
      GROUP BY s_domain
      HAVING (is_malware = '' AND is_phishing = '')
         AND ((business_model != '' AND crawlable)
              OR ((last_http_blocked != '' OR last_http_status IN (401, 403, 429)) AND dns_mx != ''))
    ) h
    LEFT JOIN (
      SELECT
        domain,
        max(enriched_at) AS enriched_at_newest,
        argMax(render_engine, enriched_at) AS render_engine,
        /* Numerics are Nullable BY DESIGN: NULL = "could not look" (sub-fetch
           failed inside an otherwise-successful crawl), 0 = "looked, found
           none". argMaxIf(col, ts, col IS NOT NULL) keeps the last MEASURED
           value — so a real newer measurement (including a genuine zero)
           replaces, and a blind spot never erases. Same philosophy as the
           h-side's 50 argMaxIfs, applied to depth. */
        argMaxIf(product_count, enriched_at, product_count IS NOT NULL) AS product_count,
        argMaxIf(price_min, enriched_at, price_min IS NOT NULL) AS price_min,
        argMaxIf(price_avg, enriched_at, price_avg IS NOT NULL) AS price_avg,
        argMaxIf(price_max, enriched_at, price_max IS NOT NULL) AS price_max,
        argMaxIf(new_products_30d, enriched_at, new_products_30d IS NOT NULL) AS new_products_30d,
        argMaxIf(last_product_at, enriched_at, last_product_at IS NOT NULL) AS last_product_at,
        argMaxIf(oos_ratio, enriched_at, oos_ratio IS NOT NULL) AS oos_ratio,
        argMaxIf(discount_depth, enriched_at, discount_depth IS NOT NULL) AS discount_depth,
        argMaxIf(vendor_count, enriched_at, vendor_count IS NOT NULL) AS vendor_count,
        argMaxIf(catalog_age_days, enriched_at, catalog_age_days IS NOT NULL) AS catalog_age_days,
        argMaxIf(job_count, enriched_at, job_count IS NOT NULL) AS job_count,
        argMaxIf(seo_score, enriched_at, seo_score IS NOT NULL) AS seo_score,
        argMaxIf(seo_word_count, enriched_at, seo_word_count IS NOT NULL) AS seo_word_count,
        argMaxIf(seo_alt_ratio, enriched_at, seo_alt_ratio IS NOT NULL) AS seo_alt_ratio,
        argMaxIf(perf_lcp_ms, enriched_at, perf_lcp_ms IS NOT NULL) AS perf_lcp_ms,
        argMaxIf(perf_cls, enriched_at, perf_cls IS NOT NULL) AS perf_cls,
        argMaxIf(perf_ttfb_ms, enriched_at, perf_ttfb_ms IS NOT NULL) AS perf_ttfb_ms,
        /* Strings use '' for both "none" and "could not look" (the writers
           cannot tell them apart), so last non-empty wins. Trade-off: a store
           that genuinely removes its about page keeps the old text until the
           next full crawl that finds a replacement. Cheap next to the numeric
           columns, which are what buyers filter on. */
        argMaxIf(product_types, enriched_at, product_types != '') AS product_types,
        argMaxIf(ats_platform, enriched_at, ats_platform != '') AS ats_platform,
        argMaxIf(job_departments, enriched_at, job_departments != '') AS job_departments,
        argMaxIf(job_locations, enriched_at, job_locations != '') AS job_locations,
        argMaxIf(seo_issues, enriched_at, seo_issues != '') AS seo_issues,
        argMaxIf(about_text, enriched_at, about_text != '') AS about_text,
        argMaxIf(mission, enriched_at, mission != '') AS mission,
        argMaxIf(hq_location, enriched_at, hq_location != '') AS hq_location,
        argMaxIf(job_locations_top, enriched_at, job_locations_top != '') AS job_locations_top,
        argMaxIf(positions_overview, enriched_at, positions_overview != '') AS positions_overview
      FROM (SELECT * FROM biz_enrichment_log #{depth_scope})
      GROUP BY domain
    ) s ON h.domain = s.domain
    LEFT JOIN (SELECT domain, count() AS pricing_points FROM biz_pricing#{join_scope} GROUP BY domain) p
           ON h.domain = p.domain
    LEFT JOIN (SELECT domain, count() AS news_count,
                      max(amount_usd) AS last_funding_usd
               FROM biz_news#{join_scope} GROUP BY domain) n ON h.domain = n.domain
    LEFT JOIN (#{verified_sql(join_scope)}) v ON h.domain = v.domain
    SETTINGS max_bytes_before_external_group_by = 1500000000, max_threads = 2,
             join_use_nulls = 1
    """
  end

  # ── Raw + Public ──

  @doc "POST a prepared INSERT (`sql`) with a TabSeparated `body`. Used by the enrichment writer."
  @spec insert_raw(String.t(), String.t()) :: :ok | {:error, term()}
  def insert_raw(sql, body) do
    # A trailing newline after "FORMAT TabSeparated" in the query param makes
    # ClickHouse treat the remainder as inline data and mis-frame the first
    # body row ("expected '\t' before ..."). Heredoc-built SQL always carries
    # that newline — the platforms flush failed on every attempt for a day
    # while byte-identical data inserted fine from single-line SQL. Trim here
    # so no caller can trip on it again.
    url = "#{@ch_url}?database=#{@ch_db}&query=#{URI.encode(String.trim_trailing(sql))}"

    case Req.post(url, finch: LS.Finch.CH, pool_timeout: 15_000, body: body <> "\n", receive_timeout: 30_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "CH #{s}: #{String.slice(to_string(b), 0, 200)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  # Which connection pool a call uses. `background: true` routes to the small
  # LS.Finch.CHBackground pool so a long-running compaction can never consume
  # the connections the web tier needs — the 2026-08-27 outage. Anything a
  # user is waiting on stays on the big pool.
  def finch_for(opts) do
    if Keyword.get(opts, :background, false), do: LS.Finch.CHBackground, else: LS.Finch.CH
  end

  @doc """
  Run `sql` and return `{:ok, rows}`.

  The URL carries `cancel_http_readonly_queries_on_client_close=1` because a
  client timeout does NOT stop ClickHouse on its own. On 2026-08-24 that cost
  the dashboard an outage: the Explorer's Req gives up after 20s, but the
  abandoned SELECT kept running server-side for 250s+; the user retried, each
  retry queued another, and 16 identical scans piled up on an already-saturated
  box until every query timed out and the page showed "Search unavailable".
  With this setting the server drops the query the moment we hang up, so a slow
  page can no longer snowball into an outage. It applies to readonly queries
  only, so compaction and other INSERTs are untouched.
  """
  def query_raw(sql, receive_timeout \\ @timeout, opts \\ []) do
    # max_execution_time is opt-in per call, NOT derived from receive_timeout:
    # compaction deliberately outlives its client budget (a pass that reports a
    # client timeout at 300s can still finish and commit server-side), and
    # capping it would turn a slow compaction into a failed one. Read paths
    # that a user is waiting on pass it explicitly — see LS.Explorer.
    server_cap =
      case opts[:max_execution_time] do
        s when is_integer(s) and s > 0 -> "&max_execution_time=#{s}"
        _ -> ""
      end

    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact&cancel_http_readonly_queries_on_client_close=1#{server_cap}"
    case Req.post(url, finch: finch_for(opts), pool_timeout: 15_000, body: sql, receive_timeout: receive_timeout) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      # DDL / OPTIMIZE / statements with no result set return an empty 200 body.
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "CH #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def escape_public(str), do: escape(str)

  @doc """
  Run `sql` and return what it cost: `{:ok, %{elapsed_ms, rows_read, bytes_read, rows_returned}}`.

  For performance tests. `elapsed_ms` is ClickHouse's own server-side timing, not
  the client clock, so a budget means the same thing over an SSH tunnel as it does
  on the master. `bytes_read` is a property of the query plan rather than the
  hardware, so it catches a regression to a full-scan shape even on a box fast
  enough to hide the latency.
  """
  def measure(sql, receive_timeout \\ @timeout) do
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSON"

    case Req.post(url, finch: LS.Finch.CH, pool_timeout: 15_000, body: sql, receive_timeout: receive_timeout) do
      {:ok, %{status: 200, body: %{"statistics" => stats} = body}} ->
        {:ok,
         %{
           elapsed_ms: round(stats["elapsed"] * 1000),
           rows_read: stats["rows_read"],
           bytes_read: stats["bytes_read"],
           rows_returned: body["rows"]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "CH #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Private ──

  defp query(sql) do
    # Same cancel-on-hangup guarantee as query_raw/3. This private helper backs
    # most of the public page queries (tech, top, compare, store, landing), and
    # it built its OWN url — so on 2026-08-24 those paths stayed unbounded while
    # query_raw was already fixed: 62 of 68 in-flight Explorer-shaped scans
    # carried no cap at all. Every read path must hang up together or the
    # pile-up simply moves to whichever one was missed.
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact&cancel_http_readonly_queries_on_client_close=1"
    case Req.post(url, finch: LS.Finch.CH, pool_timeout: 15_000, body: sql, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, "CH #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Country inference expression ──
  # Computes inferred country at query time from existing columns.
  # Uses same logic as LS.CountryInferrer: TLD > language > BGP fallback.
  # Once inferred_country column is populated, this falls through to it first.
  @doc """
  Source of truth for the `country` MATERIALIZED column on ClickHouse's
  `.inner_id.*` table behind `domains_current` (exposed for reads as the
  `domains_fast` view — see `devops/listsignal/clickhouse_materialize.sql`).

  No query interpolates this any more: evaluating a ~100-branch multiIf over 81M
  rows cost 8-11s and blew the app timeout, which surfaced as a 404 on every
  /top/* page. It is now computed once at insert time and read as a column.

  **If you change this, you must re-run the ALTER + MATERIALIZE COLUMN in that
  file**, or the stored column silently drifts from this definition.
  """
  def country_expr do
    """
    multiIf(
      inferred_country != '', inferred_country,
      ctl_tld IN ('co.uk','org.uk','ac.uk','gov.uk','net.uk'), 'GB',
      ctl_tld IN ('com.au','co.au','net.au','org.au','edu.au','gov.au'), 'AU',
      ctl_tld IN ('co.nz','ac.nz','net.nz','org.nz'), 'NZ',
      ctl_tld IN ('co.za','net.za','org.za','gov.za','ac.za'), 'ZA',
      ctl_tld IN ('com.br','net.br'), 'BR',
      ctl_tld IN ('com.cn','net.cn','org.cn','edu.cn'), 'CN',
      ctl_tld = 'co.jp', 'JP', ctl_tld = 'co.kr', 'KR',
      ctl_tld = 'co.in', 'IN', ctl_tld = 'co.il', 'IL',
      ctl_tld = 'co.id', 'ID', ctl_tld = 'co.th', 'TH',
      ctl_tld = 'co.ke', 'KE', ctl_tld = 'co.tz', 'TZ',
      ctl_tld = 'com.mx', 'MX', ctl_tld = 'com.ar', 'AR',
      ctl_tld = 'com.sg', 'SG', ctl_tld = 'com.my', 'MY',
      ctl_tld = 'com.ph', 'PH', ctl_tld = 'com.tw', 'TW',
      ctl_tld = 'com.ua', 'UA', ctl_tld = 'com.tr', 'TR',
      ctl_tld = 'com.pk', 'PK', ctl_tld = 'com.sa', 'SA',
      ctl_tld = 'com.eg', 'EG', ctl_tld = 'com.ng', 'NG',
      ctl_tld = 'com.gh', 'GH', ctl_tld = 'com.co', 'CO',
      ctl_tld = 'com.pe', 'PE', ctl_tld = 'com.ve', 'VE',
      ctl_tld = 'com.hk', 'HK',
      ctl_tld = 'fr', 'FR', ctl_tld = 'de', 'DE', ctl_tld = 'jp', 'JP',
      ctl_tld = 'ca', 'CA', ctl_tld = 'uk', 'GB', ctl_tld = 'it', 'IT',
      ctl_tld = 'es', 'ES', ctl_tld = 'nl', 'NL', ctl_tld = 'se', 'SE',
      ctl_tld = 'no', 'NO', ctl_tld = 'dk', 'DK', ctl_tld = 'fi', 'FI',
      ctl_tld = 'be', 'BE', ctl_tld = 'ch', 'CH', ctl_tld = 'at', 'AT',
      ctl_tld = 'pl', 'PL', ctl_tld = 'pt', 'PT', ctl_tld = 'br', 'BR',
      ctl_tld = 'mx', 'MX', ctl_tld = 'il', 'IL', ctl_tld = 'in', 'IN',
      ctl_tld = 'sg', 'SG', ctl_tld = 'ae', 'AE', ctl_tld = 'za', 'ZA',
      ctl_tld = 'nz', 'NZ', ctl_tld = 'au', 'AU', ctl_tld = 'ie', 'IE',
      ctl_tld = 'kr', 'KR', ctl_tld = 'tw', 'TW', ctl_tld = 'hk', 'HK',
      ctl_tld = 'ru', 'RU', ctl_tld = 'tr', 'TR', ctl_tld = 'cz', 'CZ',
      ctl_tld = 'hu', 'HU', ctl_tld = 'ro', 'RO', ctl_tld = 'bg', 'BG',
      ctl_tld = 'gr', 'GR', ctl_tld = 'ua', 'UA', ctl_tld = 'th', 'TH',
      ctl_tld = 'vn', 'VN', ctl_tld = 'id', 'ID', ctl_tld = 'my', 'MY',
      ctl_tld = 'ar', 'AR', ctl_tld = 'pe', 'PE', ctl_tld = 'cl', 'CL',
      ctl_tld = 'cn', 'CN', ctl_tld = 'us', 'US', ctl_tld = 'eu', 'EU',
      ctl_tld = 'ng', 'NG', ctl_tld = 'gh', 'GH', ctl_tld = 'ke', 'KE',
      ctl_tld = 'eg', 'EG', ctl_tld = 'sa', 'SA', ctl_tld = 'pk', 'PK',
      ctl_tld = 'ph', 'PH', ctl_tld = 'bd', 'BD', ctl_tld = 'lk', 'LK',
      ctl_tld = 'hr', 'HR', ctl_tld = 'si', 'SI', ctl_tld = 'sk', 'SK',
      ctl_tld = 'rs', 'RS', ctl_tld = 'lt', 'LT', ctl_tld = 'lv', 'LV',
      ctl_tld = 'ee', 'EE', ctl_tld = 'lu', 'LU', ctl_tld = 'is', 'IS',
      http_language = 'fr', 'FR', http_language = 'de', 'DE',
      http_language = 'ja', 'JP', http_language = 'ko', 'KR',
      http_language = 'zh', 'CN', http_language = 'ru', 'RU',
      http_language = 'pt', 'BR', http_language = 'it', 'IT',
      http_language = 'nl', 'NL', http_language = 'sv', 'SE',
      http_language = 'da', 'DK', http_language = 'no', 'NO',
      http_language = 'fi', 'FI', http_language = 'pl', 'PL',
      http_language = 'cs', 'CZ', http_language = 'hu', 'HU',
      http_language = 'ro', 'RO', http_language = 'bg', 'BG',
      http_language = 'el', 'GR', http_language = 'tr', 'TR',
      http_language = 'th', 'TH', http_language = 'vi', 'VN',
      http_language = 'id', 'ID', http_language = 'ms', 'MY',
      http_language = 'uk', 'UA', http_language = 'he', 'IL',
      http_language = 'ar', 'SA', http_language = 'hi', 'IN',
      http_language = 'es', 'ES', http_language = 'sco', 'GB',
      http_language = 'en', 'US',
      bgp_asn_country != '' AND length(bgp_asn_country) = 2
        AND NOT (bgp_asn_country = 'CA' AND startsWith(bgp_ip, '23.227.3')), bgp_asn_country,
      'US'
    )\
    """
    |> String.trim()
  end

  defp escape(str) do
    str |> String.replace("\\", "\\\\") |> String.replace("'", "\\'") |> String.replace(";", "")
  end
end
