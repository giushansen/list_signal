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
    SELECT domain, http_title, estimated_country, tranco_rank,
           estimated_revenue, estimated_business_model, shop_product_count, shop_price_avg,
           hr_job_count, http_deep_seo_score, notEmpty(http_emails) AS has_contact
    FROM businesses
    WHERE is_shopify = 1
      AND http_title != '' AND http_deep_last_seen_at IS NOT NULL
      AND estimated_revenue != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT 1 BY domain
    LIMIT #{limit}
    """)
  end

  @doc """
  A ranked sample of non-ecommerce online businesses (SaaS, agencies,
  marketplaces...) for the landing page. Mirrors `sample_shopify_stores/1`
  so the two tables read the same: the homepage must show that the dataset
  is every digital business, not a Shopify directory.

  Both samples read WITHOUT FINAL and dedupe the ten rows they return with
  `LIMIT 1 BY domain` (2026-09-09). With FINAL each was a 3.3s, 3 GB sort of
  the whole table, and LS.LandingCache asked every 60s: 2,200 runs and
  7,000 CPU-seconds a day, 57% of all FINAL read time, to refresh a sample
  of ten that changes by the day. The hourly optimizer keeps duplicates at
  0.07%, and a duplicate cannot reach the page through the LIMIT 1 BY.
  """
  def sample_online_businesses(limit \\ 6) do
    query("""
    SELECT domain, http_title, estimated_country, tranco_rank,
           estimated_revenue, estimated_business_model, estimated_industry,
           hr_job_count, http_deep_seo_score, notEmpty(http_emails) AS has_contact, arrayStringConcat(http_tech, '|')
    FROM businesses
    WHERE estimated_business_model IN ('SaaS', 'Agency', 'Marketplace', 'Tool', 'Media')
      AND http_title != '' AND http_deep_last_seen_at IS NOT NULL
      AND estimated_revenue != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT 1 BY domain
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
           query("SELECT countIf(hr_job_count > 0), toUInt64(sum(hr_job_count)) FROM businesses FINAL SETTINGS max_threads=2"),
         {:ok, depts} <-
           query("""
           SELECT dept, count() AS companies FROM (
             SELECT arrayJoin(hr_departments) AS dept
             FROM businesses FINAL
             WHERE hr_job_count > 0 AND notEmpty(hr_departments)
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
         SELECT verified_revenue, verified_revenue_evidence, verified_employees, verified_employees_evidence, estimated_summary
         FROM businesses WHERE domain = '#{escape(domain)}' ORDER BY compiled_at DESC LIMIT 1
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
    case query("SELECT http_deep_seo_score FROM businesses WHERE domain = '#{escape(domain)}' LIMIT 1") do
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
    SELECT domain, estimated_country, http_title, arrayStringConcat(http_tech, '|'), compiled_at
    FROM businesses
    WHERE estimated_business_model IN (#{list}) AND estimated_junk = '' AND http_title != ''
      AND estimated_business_model_confidence >= 0.5 AND #{not_challenge_sql("http_title")}
    ORDER BY compiled_at DESC
    LIMIT #{limit}
    """)
  end

  # ── Store profile ──

  # Rows come back as MAPS keyed by domains_current's OWN column names
  # (2026-09-07). They used to be positional lists that the store page and
  # the lookup tool indexed with LS.Cluster.Inserter.columns/0; that list
  # gained nine columns on 09-06/07 that domains_current does not have, so
  # every field after dns_cname read its neighbour: titles came out as page
  # lists for a day, and once the shift reached classification_confidence a
  # float hit decode_html/1 (104 FunctionClauseErrors in ten minutes,
  # reported by the other session). A row is now self-describing.
  def get_store(domain) when is_binary(domain) do
    case query("SELECT * FROM #{LS.Schema.Tables.domains()} FINAL WHERE domain = '#{escape(domain)}' LIMIT 1") do
      {:ok, rows} -> {:ok, Enum.map(rows, &(domains_current_columns() |> Enum.zip(&1) |> Map.new()))}
      err -> err
    end
  end

  @doc """
  domains_current's physical column order, as atoms, read once from the
  server and cached. The inserter's list is the wrong key for a
  `SELECT *` on this table (see get_store/1).
  """
  @spec domains_current_columns() :: [atom()]
  def domains_current_columns do
    case :persistent_term.get({__MODULE__, :domains_current_columns}, nil) do
      cols when is_list(cols) ->
        cols

      nil ->
        case query_raw("SELECT name FROM system.columns WHERE database = currentDatabase() AND table = '#{LS.Schema.Tables.domains()}' ORDER BY position", 5_000) do
          {:ok, [_ | _] = rows} ->
            cols = Enum.map(rows, fn [n] -> String.to_atom(n) end)
            :persistent_term.put({__MODULE__, :domains_current_columns}, cols)
            cols

          _ ->
            LS.Cluster.Inserter.columns()
        end
    end
  end

  # ── Sitemap ──

  def scan_rate_per_minute do
    case query("SELECT count() FROM enrich_log WHERE enriched_at >= now() - INTERVAL 1 MINUTE") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def scan_rate_per_second do
    case query("SELECT count() / 60.0 FROM enrich_log WHERE enriched_at >= now() - INTERVAL 1 MINUTE") do
      {:ok, [[rate]]} when is_number(rate) -> Float.round(rate / 1.0, 1)
      _ -> nil
    end
  end

  def stores_last_hour do
    case query("SELECT count() FROM enrich_log WHERE enriched_at >= now() - INTERVAL 1 HOUR") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def shopify_stores_last_hour do
    # NB: `is_shopify` only exists on domains_fast (materialized on the MV
    # inner table) — on the raw domains_history log we must use the expression it
    # materializes. The previous version queried `is_shopify` here, got
    # UNKNOWN_IDENTIFIER on every call, and silently returned nil.
    case query("SELECT count() FROM enrich_log WHERE enriched_at >= now() - INTERVAL 1 HOUR AND http_tech LIKE '%Shopify%'") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  @doc """
  Latest observed changes for one domain (public store-page teaser).
  biz_signal is small and keyed (dataset-wide scans are cheap); LIMIT keeps it O(1)-ish.
  """
  def recent_signals(domain, limit \\ 5) do
    query("""
    SELECT concat(replaceAll(field, '_', ' '), ' ', change) AS kind,
           if(prev_value != '', concat(prev_value, ' to ', value), value) AS value,
           changed_at
    FROM changes_log
    WHERE domain = '#{escape(domain)}'
    ORDER BY changed_at DESC LIMIT #{limit}
    """)
  end

  @doc "How many other businesses share this model+country — the store-page teaser hook."
  def count_similar(business_model, country) when business_model != "" do
    query("""
    SELECT count() FROM businesses
    WHERE estimated_business_model = '#{escape(business_model)}'
      AND estimated_country = '#{escape(country)}' AND estimated_junk = ''
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
          {"", "ORDER BY compiled_at DESC", :unranked}
      end

    LS.LandingCache.cached({:similar_stores, business_model, country, tier, bucket}, @similar_stores_ttl, fn ->
      query("""
      SELECT domain, http_title, tranco_rank, is_shopify
      FROM businesses
      WHERE estimated_business_model = '#{escape(business_model)}'
        AND estimated_country = '#{escape(country)}'
        AND estimated_revenue IN (#{tier_sql})
        AND estimated_business_model_confidence >= 0.5
        AND estimated_junk = '' AND http_title != ''
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
      SELECT countIf(change='added'   AND changed_at >= now() - INTERVAL 7 DAY),
             countIf(change='removed' AND changed_at >= now() - INTERVAL 7 DAY),
             countIf(change='added'   AND changed_at >= now() - INTERVAL 30 DAY),
             countIf(change='removed' AND changed_at >= now() - INTERVAL 30 DAY)
      FROM changes_log
      WHERE field = 'http_tech' AND value = '#{escape(tech)}' AND change IN ('added','removed')
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
      SELECT value, countIf(change='added') AS adds, countIf(change='removed') AS drops
      FROM changes_log
      WHERE field = 'http_tech' AND changed_at >= now() - INTERVAL 30 DAY AND change IN ('added','removed')
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
      SELECT domain, max(changed_at) AS at FROM changes_log
      WHERE field = 'http_tech' AND change = 'added' AND value = '#{escape(tech)}'
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
      SELECT domain, max(changed_at) AS at FROM changes_log
      WHERE field = 'http_tech' AND changed_at >= now() - INTERVAL #{days} DAY
        AND ((change='removed' AND value='#{escape(from)}')
          OR (change='added'  AND value='#{escape(to)}'))
      GROUP BY domain
      HAVING countIf(change='removed' AND value='#{escape(from)}') > 0
         AND countIf(change='added'  AND value='#{escape(to)}') > 0
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
        :industry -> "estimated_industry = '#{escape(name)}'"
        :model -> "estimated_business_model = '#{escape(name)}'"
        # /top/shopify — a platform, not a model, so match the tech stack
        :tech -> "has(http_tech, '#{escape(name)}')"
      end

    LS.LandingCache.cached({:top_segment, kind, name}, @trend_ttl, fn ->
      query("""
      SELECT domain, http_title, arrayStringConcat(http_tech, '|'), estimated_country, tranco_rank
      FROM businesses
      WHERE estimated_junk = '' AND http_title != '' AND #{where}
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
      WHERE estimated_junk = '' AND http_title != '' AND #{field} != ''
      GROUP BY #{field}
      """)
    end)
    |> case do
      {:ok, rows} -> Map.new(rows, fn [k, v] -> {k, v} end)
      _ -> %{}
    end
  end

  defp segment_field(:industry), do: "estimated_industry"
  defp segment_field(:model), do: "estimated_business_model"

  # ── changes_log, stable domains: see LS.Clickhouse.Compact ──

  alias LS.Clickhouse.Compact

  defdelegate observed_sql(prefix \\ ""), to: Compact
  defdelegate stable_domains(since_unix, until_unix), to: Compact
  defdelegate stable_domains_sql(since_unix, until_unix), to: Compact
  defdelegate backfill_changes_shard(shard, total), to: Compact

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
        String.contains?(base, "WHERE") -> base <> " AND ctl_first_seen_at > now() - INTERVAL #{days} DAY"
        true -> base <> " WHERE ctl_first_seen_at > now() - INTERVAL #{days} DAY"
      end

    case query_raw(sql) do
      {:ok, [[n]]} -> {:ok, to_count(n)}
      err -> err
    end
  end

  @doc "Added/removed counts for one tech over `days` — the digest's signal line."
  def signal_counts_for(tech, days) do
    sql = """
    SELECT countIf(change = 'added') AS added, countIf(change = 'removed') AS removed
    FROM changes_log
    WHERE field = 'http_tech' AND value = '#{escape(tech)}' AND changed_at > now() - INTERVAL #{days} DAY
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
    WHERE is_shopify = 1
      AND notEmpty(http_emails)
      AND ctl_first_seen_at > now() - INTERVAL #{days} DAY
    SETTINGS max_threads = 2
    """

    case query_raw(sql) do
      {:ok, [[n]]} -> {:ok, to_count(n)}
      err -> err
    end
  end

  # ── Recrawl scheduler ──

  @doc "Domain and tier ('a', 'b', 'c') of every non-junk business compiled in the window (LS.Crawl.Tiers)."
  @spec compiled_tiers(integer(), integer()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def compiled_tiers(since_unix, until_unix) do
    case query_raw(LS.Crawl.Tiers.compiled_tiers_sql(since_unix, until_unix), 70_000) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [d, t] -> {d, t} end)}
      err -> err
    end
  end

  @doc false
  # The due query, with its exclusions written here: 403/503 are a WAF wall
  # and belong to the browser lane (2026-09-04, second Vultr report); a
  # robots.txt opt-out is a promise on /bot; 429 is kept on purpose, one
  # polite request after two months is what "come back later" asks for
  # (2026-08-02: excluding it would silently lose 388K domains).
  def stale_domains_sql(limit) when is_integer(limit) and limit > 0 do
    a = LS.Crawl.Tiers.cadence_days(:a)
    b = LS.Crawl.Tiers.cadence_days(:b)
    c = LS.Crawl.Tiers.cadence_days(:c)

    """
    SELECT domain, tier FROM (
      SELECT domain, #{LS.Crawl.Tiers.tier_sql()} AS tier, http_last_checked_at
      FROM #{LS.Schema.Tables.businesses()}
      WHERE estimated_junk = '' AND http_error != 'robots_disallow' AND http_blocked = ''
        AND (http_status IS NULL OR http_status NOT IN (403, 503))
        AND http_last_checked_at < now() - INTERVAL #{a} DAY
    )
    WHERE http_last_checked_at < now() - INTERVAL multiIf(tier = 'a', #{a}, tier = 'b', #{b}, #{c}) DAY
    ORDER BY tier ASC, http_last_checked_at ASC
    LIMIT #{limit}
    SETTINGS max_threads = 2, max_execution_time = 110
    """
  end

  @doc """
  Businesses due for a refresh under their tier cadence (LS.Crawl.Tiers: A
  14 days, B 60, C 120), most valuable tier first, oldest first, as
  `{domain, tier}`. Until 2026-10-03 this read the 57 GB `domains` table
  FINAL for 5,000 rows every six hours with a 7/30-day rule.
  """
  @spec stale_domains(pos_integer()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def stale_domains(limit) do
    case query_raw(stale_domains_sql(limit), 120_000) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [d, t] -> {d, t} end)}
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
    # 503 joined 401/403 on 2026-09-04 (second Vultr abuse report): a WAF
    # that answers 503 to a plain client is refusing bots, exactly like a
    # 403, so those domains belong to the browser lane — camoufox is a real
    # Firefox that passes the challenge instead of failing it. 429 stays in
    # the HTTP lane on purpose: it means "come back later", not "you need a
    # better fingerprint" (2026-08-02, when 429s were 83% of all failures
    # and drowned the scarce browser bucket — see regressions_test.exs).
    # A robots.txt opt-out (2026-09-06) leaves BOTH lanes: the browser lane
    # is not a way around a Disallow, it is the same bot with a renderer.
    if Keyword.get(opts, :browser_only, false) do
      "(b.http_blocked != '' OR b.http_status IN (401, 403, 503)) " <>
        "AND b.http_error != 'robots_disallow'"
    else
      "b.http_crawlable AND b.http_blocked = '' AND b.http_error != 'robots_disallow' AND " <>
        "(b.http_status IS NULL OR b.http_status NOT IN (401, 403, 503))"
    end
  end

  # Raw log columns the refill joins for the estimator (see the SQL below).
  @refill_log_columns ~w(dns_txt dns_ptr dns_cname dns_ms_enterprise)
  @doc false
  def refill_log_columns, do: @refill_log_columns

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

    # The candidate set, chosen on narrow columns first (2026-09-10 incident:
    # sorting the full wide row for every candidate needed 4.6 GiB). It is
    # interpolated twice below, once for the raw-DNS join side and once for
    # the main WHERE: a few hundred to a few thousand domains, cheap either way.
    picked = """
      -- Two phases (2026-09-10 incident): choose the domains on narrow
      -- columns, then read the wide row for those only. Sorting the full
      -- 30-column row for every candidate needed 4.6 GiB; next to the
      -- compactor's 1.7 GiB the server's 6.5 GiB total refused this query on
      -- every run from 09-08 (262 of 266 runs, "memory limit exceeded"), the
      -- HTTP lane refilled nothing for two days and pipeline 2 fell from
      -- ~400K rows a day to ~75K. The new form measured 1.9s and 534 MB.
      --
      -- "Not enriched in the last 30 days" reads businesses'
      -- depth_enriched_at (the compactor's newest successful enrichment),
      -- not a 14M-domain NOT IN set over biz_enrichment, which alone cost
      -- 1.8 GiB. The 7-day set covers what the column cannot: attempts that
      -- FAILED (never compiled into the column; 82K of 697K sampled
      -- domains) and the minutes before a success is compiled. So a failed
      -- attempt is retried after 7 days instead of 30, on purpose.
      SELECT i.domain FROM businesses i
      WHERE #{String.replace(lane_filter, "b.", "i.")}
        AND notEmpty(i.dns_a)
        AND (i.http_deep_last_seen_at IS NULL OR i.http_deep_last_seen_at < now() - INTERVAL 30 DAY)
        AND i.domain NOT IN (SELECT domain FROM #{LS.Schema.Tables.http_deep_state()} WHERE enriched_at >= now() - INTERVAL 7 DAY)
        -- A domain that rate-limited us is not worth retrying on the ordinary
        -- cadence: it asked for patience, and re-asking daily is how a source
        -- IP earns a permanent block. Give it a fortnight.
        AND (i.http_status != 429 OR i.compiled_at < now() - INTERVAL 14 DAY)
      -- Value-first ordering, not Tranco-only: only 5.4% of businesses carry a
      -- Tranco rank (storeradar-shaped SMBs carry none), so pure tranco order
      -- left 94% of the table in arbitrary order. Majestic (backlinks) is an
      -- independent second rank, scaled 1M->4.2M; unranked businesses are then
      -- ordered by commercial signals instead of nothing.
      ORDER BY
        least(coalesce(i.tranco_rank, 99999999), coalesce(i.majestic_rank * 4, 99999999)) ASC,
        notEmpty(i.http_emails) + notEmpty(i.dns_mx) + (i.estimated_business_model_confidence >= 0.6) DESC
      -- businesses is read WITHOUT FINAL, so every compactor pass contributes
      -- another version row per changed domain; without this each version
      -- became its own queue entry (top domains up to 9x, 2026-07-31).
      LIMIT 1 BY i.domain
      LIMIT #{limit}
    """

    sql = """
    SELECT b.domain, arrayStringConcat(b.http_pages_found, '|'), arrayStringConcat(b.http_tech, '|'), b.http_blocked, b.http_status,
      -- inferred_country is load-bearing for phone extraction, not decoration:
      -- a number printed "030 12345678" cannot be normalised to E.164 without
      -- it, and guessing a country prefix mints a number that dials a real
      -- stranger. With the country known every phone found on the German
      -- sample normalised; without it, 55% did (2026-08-27).
      b.estimated_country,
      -- Depth tier from signals we already hold. FULL treatment for businesses
      -- worth the extra pages: any rank, any email, a mail server plus solid
      -- classification, or a commerce fingerprint (catalog data pays). The
      -- rest get the LIGHT pass — homepage + contact only, no browser
      -- fallback — at roughly a third of the cost. Nothing is excluded;
      -- the tail is just crawled proportionally to its value.
      if(b.tranco_rank IS NOT NULL OR b.majestic_rank IS NOT NULL
         OR notEmpty(b.http_emails)
         OR (notEmpty(b.dns_mx) AND b.estimated_business_model_confidence >= 0.6)
         OR has(b.http_tech, 'Shopify'),
         'full', 'light') AS tier,
      -- Everything the revenue estimator reads (2026-09-06): the depth pass
      -- re-estimates with catalog, apps, sitemap and jobs on top of these,
      -- and carrying them in the queue item beats a point query per business.
      b.tranco_rank, b.majestic_rank, b.majestic_ref_subnets, b.rdap_registrar, b.ctl_issuer,
      arrayStringConcat(b.dns_mx, '|'), x.dns_txt, b.dns_dmarc, b.dns_bimi, b.dns_dkim, x.dns_ptr, x.dns_ms_enterprise,
      b.http_apps, b.ctl_subdomain_count, arrayStringConcat(b.ctl_subdomains, '|'), b.rdap_created_at, b.bgp_asn_org, b.bgp_asn,
      b.estimated_business_model, b.estimated_industry, b.http_title, b.http_status, arrayStringConcat(b.http_emails, '|'), b.http_schema_type,
      arrayStringConcat(b.rdap_nameservers, '|'), arrayStringConcat(b.dns_a, '|'), x.dns_cname
    FROM businesses b
    -- The raw DNS strings the estimator reads (TXT, PTR, CNAME, the Microsoft
    -- tenant flag) are not in the product table (data model v2). They come
    -- from the log's newest row: enrich_log is keyed (domain, enriched_at),
    -- so this is a primary-key read for the picked set. Not from `domains`:
    -- that table was never given dns_ptr or dns_ms_enterprise, and the first
    -- v2 boot (2026-10-01 08:26) failed this refill on prod with Code 47
    -- for an hour while the harness, which had the columns, stayed green.
    LEFT JOIN (
      SELECT domain, #{Enum.join(@refill_log_columns, ", ")}
      FROM #{LS.Schema.Tables.enrich_log()}
      WHERE domain IN (#{picked})
      ORDER BY enriched_at DESC
      LIMIT 1 BY domain
    ) AS x ON b.domain = x.domain
    WHERE b.domain IN (
#{picked}
    )
    ORDER BY least(coalesce(b.tranco_rank, 99999999), coalesce(b.majestic_rank * 4, 99999999)) ASC
    LIMIT 1 BY b.domain
    SETTINGS max_threads = 2, max_memory_usage = 2500000000, join_use_nulls = 0
    """

    # 90s, not the 25s default: this is a background refill on a 5-minute timer,
    # and on a loaded box the 25s budget expired before the scan finished. The
    # queue then got NOTHING, so the enrichment-only nodes sat idle with a
    # 257K backlog waiting (2026-08-24).
    case query_raw(sql, 90_000) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn [d, pages, tech, blocked, status, country, tier | est] ->
           %{domain: d, http_pages: pages, http_tech: tech,
             http_blocked: blocked, last_http_status: status,
             inferred_country: country, tier: tier,
             est: Enum.zip(estimator_columns(), est) |> Map.new() |> Map.merge(%{domain: d, http_tech: tech, inferred_country: country})}
         end)}

      err ->
        err
    end
  end

  @doc false
  # Order matches the trailing columns of businesses_needing_enrichment/2.
  def estimator_columns,
    do: ~w(tranco_rank majestic_rank majestic_ref_subnets rdap_registrar ctl_issuer
           dns_mx dns_txt dns_dmarc dns_bimi dns_dkim dns_ptr dns_ms_enterprise
           http_apps ctl_subdomain_count ctl_subdomains rdap_domain_created_at bgp_asn_org bgp_asn_number
           business_model industry http_title http_status http_emails http_schema_type
           rdap_nameservers dns_a dns_cname)a

  # ── compaction: see LS.Clickhouse.Compact (data model v2, 2026-10-01) ──

  defdelegate compact_businesses(since_unix, until_unix \\ nil), to: Compact
  defdelegate changed_domains(since_unix, until_unix), to: Compact
  defdelegate rebuild_businesses_full(), to: Compact
  defdelegate compact_shard(shard, total_shards), to: Compact
  defdelegate compact_sql_shard_preview(shard \\ 0, total \\ 256), to: Compact
  defdelegate compact_domains(domains), to: Compact
  defdelegate compact_sql_domains(domains), to: Compact
  defdelegate verified_sql(join_scope), to: Compact
  defdelegate compact_sql_for_test(since_unix, until_unix \\ nil), to: Compact
  defdelegate history_cols(), to: Compact
  defdelegate history_rows_sql(since_unix, until_unix \\ nil), to: Compact

  defp to_count(n) when is_integer(n), do: n

  defp to_count(n) when is_binary(n) do
    case Integer.parse(n) do
      {v, _} -> v
      :error -> 0
    end
  end

  defp to_count(_), do: 0

  @spec insert_raw(String.t(), String.t()) :: :ok | {:error, term()}
  def insert_raw(sql, body) do
    # A trailing newline after "FORMAT TabSeparated" in the query param makes
    # ClickHouse treat the remainder as inline data and mis-frame the first
    # body row ("expected '\t' before ..."). Heredoc-built SQL always carries
    # that newline — the platforms flush failed on every attempt for a day
    # while byte-identical data inserted fine from single-line SQL. Trim here
    # so no caller can trip on it again.
    url = "#{@ch_url}?database=#{@ch_db}&query=#{URI.encode(String.trim_trailing(sql))}"

    case post(url, body <> "\n", finch: LS.Finch.CH, receive_timeout: 30_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "CH #{s}: #{String.slice(to_string(b), 0, 200)}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Every HTTP call to ClickHouse goes through here so all of them authenticate
  as the app's own user (security audit, 2026-09-09). Before this the app ran
  as the passwordless `default` superuser, which holds FILE, URL, REMOTE and
  DROP: one unescaped string in any query would have been a file read on the
  master. `ls_app` has SELECT and INSERT on `ls.*` plus what the index
  rebuilds and the optimizer need, and nothing else.

  `:ls, :clickhouse_req_options` lets a test route the request through a
  `Req.Test` plug instead of the network.
  """
  @spec post(String.t(), iodata(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post(url, body, opts) do
    # The pool is mandatory: an unpooled ClickHouse call shared Req's default
    # pool with the crawler and took the web tier down twice in August.
    Req.post(
      url,
      [body: body, headers: auth_headers(), finch: Keyword.fetch!(opts, :finch), pool_timeout: 15_000] ++
        Keyword.delete(opts, :finch) ++ Application.get_env(:ls, :clickhouse_req_options, [])
    )
  end

  @doc false
  def auth_headers do
    cfg = Application.get_env(:ls, :clickhouse, [])
    [{"x-clickhouse-user", cfg[:user] || "default"}, {"x-clickhouse-key", cfg[:password] || ""}]
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

    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact&cancel_http_readonly_queries_on_client_close=1#{server_cap}#{params_qs(opts[:params] || %{})}"
    case post(url, sql, finch: finch_for(opts), receive_timeout: receive_timeout) do
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
  Query-parameter suffix for a URL: `%{t: "Vue.js"}` becomes
  `&param_t=Vue.js`. Names are our own atoms or strings; values are encoded,
  so any text is safe. Public so the query builders and their tests share it.
  """
  @spec params_qs(map()) :: String.t()
  def params_qs(params) when map_size(params) == 0, do: ""

  def params_qs(params) do
    Enum.map_join(params, "", fn {k, v} -> "&param_#{k}=#{URI.encode_www_form(to_string(v))}" end)
  end

  @doc """
  A ClickHouse `Array(String)` parameter value: `['a','b']` with quotes and
  backslashes escaped, the literal form the server parses for `{x:Array(String)}`.
  """
  @spec array_param([String.t()]) :: String.t()
  def array_param(values) do
    "[" <> Enum.map_join(values, ",", fn v -> "'" <> String.replace(to_string(v), ~r/['\\]/, "\\\\\\0") <> "'" end) <> "]"
  end

  # LIMITs and thresholds are interpolated as integers only.

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

    case post(url, sql, finch: LS.Finch.CH, receive_timeout: receive_timeout) do
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

  # `params` are bound server-side as ClickHouse query parameters
  # (`{name:String}` in the SQL, `param_name=` on the URL): the value never
  # touches the SQL text, so it cannot break out of it (2026-09-09). Prefer
  # this over `escape/1` for anything a visitor typed; escape/1 is correct
  # for quotes and backslashes but drops semicolons from the text.
  @doc false
  def query(sql, params \\ %{}) do
    # Same cancel-on-hangup guarantee as query_raw/3. This private helper backs
    # most of the public page queries (tech, top, compare, store, landing), and
    # it built its OWN url — so on 2026-08-24 those paths stayed unbounded while
    # query_raw was already fixed: 62 of 68 in-flight Explorer-shaped scans
    # carried no cap at all. Every read path must hang up together or the
    # pile-up simply moves to whichever one was missed.
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact&cancel_http_readonly_queries_on_client_close=1#{params_qs(params)}"
    case post(url, sql, finch: LS.Finch.CH, receive_timeout: @timeout) do
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
