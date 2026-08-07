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

  def recent_stores(limit \\ 20) do
    query("""
    SELECT domain, country, http_title, http_tech, enriched_at
    FROM domains_fast
    WHERE is_shopify = 1 AND http_title != ''
    ORDER BY enriched_at DESC
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
    query("""
    SELECT http_language, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_language != ''
    GROUP BY http_language ORDER BY cnt DESC LIMIT 10
    """)
  end

  def tech_hosting_distribution(tech_name) do
    query("""
    SELECT bgp_asn_org, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND bgp_asn_org != ''
    GROUP BY bgp_asn_org ORDER BY cnt DESC LIMIT 10
    """)
  end

  def tech_registrar_distribution(tech_name) do
    query("""
    SELECT rdap_registrar, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND rdap_registrar != ''
    GROUP BY rdap_registrar ORDER BY cnt DESC LIMIT 10
    """)
  end

  def tech_co_occurring(tech_name) do
    query("""
    SELECT arrayJoin(splitByString('|', http_tech)) AS tech, count() AS cnt
    FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    GROUP BY tech HAVING tech != '#{escape(tech_name)}' AND cnt >= 2
    ORDER BY cnt DESC LIMIT 20
    """)
  end

  # ── VS / Compare pages ──

  def compare_techs(tech_a, tech_b) do
    count_a = tech_store_count(tech_a)
    count_b = tech_store_count(tech_b)
    {:ok, stores_a} = stores_by_tech(tech_a, 10)
    {:ok, stores_b} = stores_by_tech(tech_b, 10)
    {:ok, countries_a} = tech_country_distribution(tech_a)
    {:ok, countries_b} = tech_country_distribution(tech_b)
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
      both_count: both_count
    }
  end

  def tech_country_distribution(tech_name) do
    query("""
    SELECT country, count() AS cnt FROM domains_fast
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND country != ''
    GROUP BY country ORDER BY cnt DESC LIMIT 10
    """)
  end

  # ── Top / Ranking pages ──

  def top_stores_by_country(country_code, limit \\ 50) do
    query("""
    SELECT domain, http_title, http_tech, country, tranco_rank
    FROM domains_fast
    WHERE is_shopify = 1 AND country = '#{escape(country_code)}' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  def top_stores_using_tech(tech_name, limit \\ 50) do
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
    LEFT JOIN biz_enrichment s ON b.domain = s.domain
    -- One lane at a time — see browser_only above.
    WHERE #{lane_filter}
      AND b.dns_alive
      AND (s.enriched_at IS NULL OR s.enriched_at < now() - INTERVAL 30 DAY)
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

    case query(sql) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [d, pages, tech, blocked, status, tier] ->
           %{domain: d, http_pages: pages, http_tech: tech,
             http_blocked: blocked, last_http_status: status, tier: tier}
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
    with {:ok, _} <- query_raw(compact_sql(since_unix, until_unix), 300_000),
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
  def rebuild_businesses_full, do: query_raw(compact_sql(0), 30 * 60_000)

  @doc """
  Rebuild one hash-shard of `businesses` — the memory-safe backfill unit.

  A full rebuild in one query no longer fits the shared box (the unscoped
  joins are the same memory bomb the compactor hit on 2026-08-05). Sharding
  by domain hash keeps each pass slice-sized; 256 shards of ~37K domains run
  ~1-2 min each and the whole table backfills in hours without touching the
  6.5G cap.
  """
  def compact_shard(shard, total_shards) do
    query_raw(compact_sql_shard(shard, total_shards), 300_000)
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
    INSERT INTO businesses (domain, first_seen, as_of, last_verified_at, last_worker, crawlable, last_http_status, last_http_error, last_http_blocked, dns_alive, ctl_tld, ctl_issuer, ctl_subdomain_count, ctl_subdomains, dns_a, dns_aaaa, dns_mx, dns_txt, dns_cname, http_status, http_response_time, http_blocked, http_content_type, http_tech, http_apps, http_language, http_title, http_meta_description, http_pages, http_emails, http_h1, business_model, industry, classification_confidence, http_schema_type, http_og_type, bgp_ip, bgp_asn_number, bgp_asn_org, bgp_asn_country, bgp_asn_prefix, inferred_country, rdap_domain_created_at, rdap_domain_expires_at, rdap_domain_updated_at, rdap_registrar, rdap_registrar_iana_id, rdap_nameservers, rdap_status, tranco_rank, majestic_rank, majestic_ref_subnets, is_disposable_email, estimated_revenue, estimated_employees, revenue_confidence, revenue_evidence, product_count, price_min, price_avg, price_max, new_products_30d, last_product_at, oos_ratio, discount_depth, vendor_count, catalog_age_days, product_types, job_count, ats_platform, job_departments, job_locations, seo_score, seo_issues, seo_word_count, seo_alt_ratio, perf_lcp_ms, perf_cls, perf_ttfb_ms, render_engine, depth_enriched_at, about_text, mission, hq_location, job_locations_top, positions_overview, pricing_points, news_count, last_funding_usd)
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
      h.is_disposable_email,
      h.estimated_revenue, h.estimated_employees, h.revenue_confidence, h.revenue_evidence,
      s.product_count, s.price_min, s.price_avg, s.price_max, s.new_products_30d,
      s.last_product_at, s.oos_ratio, s.discount_depth, s.vendor_count,
      s.catalog_age_days, s.product_types,
      s.job_count, s.ats_platform, s.job_departments, s.job_locations,
      s.seo_score, s.seo_issues, s.seo_word_count, s.seo_alt_ratio,
      s.perf_lcp_ms, s.perf_cls, s.perf_ttfb_ms,
      s.render_engine, s.enriched_at_newest AS depth_enriched_at,
      s.about_text, s.mission, s.hq_location, s.job_locations_top, s.positions_overview,
      p.pricing_points, n.news_count, n.last_funding_usd
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
        if(max(s_is_disposable_email = 'true'), 'true', '') AS is_disposable_email
      FROM (SELECT enriched_at AS s_enriched_at, worker AS s_worker, domain AS s_domain, ctl_tld AS s_ctl_tld, ctl_issuer AS s_ctl_issuer, ctl_subdomain_count AS s_ctl_subdomain_count, ctl_subdomains AS s_ctl_subdomains, dns_a AS s_dns_a, dns_aaaa AS s_dns_aaaa, dns_mx AS s_dns_mx, dns_txt AS s_dns_txt, dns_cname AS s_dns_cname, http_status AS s_http_status, http_response_time AS s_http_response_time, http_blocked AS s_http_blocked, http_content_type AS s_http_content_type, http_tech AS s_http_tech, http_apps AS s_http_apps, http_language AS s_http_language, http_title AS s_http_title, http_meta_description AS s_http_meta_description, http_pages AS s_http_pages, http_emails AS s_http_emails, http_error AS s_http_error, http_h1 AS s_http_h1, business_model AS s_business_model, industry AS s_industry, classification_confidence AS s_classification_confidence, http_schema_type AS s_http_schema_type, http_og_type AS s_http_og_type, bgp_ip AS s_bgp_ip, bgp_asn_number AS s_bgp_asn_number, bgp_asn_org AS s_bgp_asn_org, bgp_asn_country AS s_bgp_asn_country, bgp_asn_prefix AS s_bgp_asn_prefix, inferred_country AS s_inferred_country, rdap_domain_created_at AS s_rdap_domain_created_at, rdap_domain_expires_at AS s_rdap_domain_expires_at, rdap_domain_updated_at AS s_rdap_domain_updated_at, rdap_registrar AS s_rdap_registrar, rdap_registrar_iana_id AS s_rdap_registrar_iana_id, rdap_nameservers AS s_rdap_nameservers, rdap_status AS s_rdap_status, tranco_rank AS s_tranco_rank, majestic_rank AS s_majestic_rank, majestic_ref_subnets AS s_majestic_ref_subnets, is_malware AS s_is_malware, is_phishing AS s_is_phishing, is_disposable_email AS s_is_disposable_email, estimated_revenue AS s_estimated_revenue, estimated_employees AS s_estimated_employees, revenue_confidence AS s_revenue_confidence, revenue_evidence AS s_revenue_evidence FROM domains_history)
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

  def query_raw(sql, receive_timeout \\ @timeout) do
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact"
    case Req.post(url, finch: LS.Finch.CH, pool_timeout: 15_000, body: sql, receive_timeout: receive_timeout) do
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
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact"
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
