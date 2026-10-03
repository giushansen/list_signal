defmodule LS.Clickhouse.Compact do
  @moduledoc """
  The compaction fold: every pipeline's newest observations, coalesced into
  one `businesses` row per domain (data model v2, 2026-10-01).

  The algorithm is the 2026-09-07 one and is unchanged in shape: a pass
  folds the window's `enrich_log` rows into what `businesses` already holds
  (`history_rows_sql/2`, three legs under one UNION ALL), joins the deep
  pass, prices, news, verified facts, certificate sightings and contacts for
  the touched domains, and writes one row per domain. What is new:

    * the INSERT list and the final SELECT are generated from
      `LS.Schema.Columns`, so a column exists in exactly one place;
    * every list column is an Array, `http_tech` carries platforms, vendors,
      plugins and apps together, filtered through the tech catalog;
    * emails and social links fold as a UNION over observations (a crawl
      that finds one address no longer erases two found earlier);
    * each pass first lands in a scratch table, `changes_log` is written
      from the scratch-vs-current diff (`LS.Schema.Changes`), then the
      scratch rows move into `businesses`.

  Fold rules, declared per column in the spec and implemented here:
  newest (status, error, block), newest non-empty from an observed fetch
  (every scalar fact), union (certificates, emails, social links), best by
  confidence (estimates, deep pass beats homepage).
  """

  alias LS.Clickhouse
  alias LS.Schema.{Changes, Columns, Tables}

  require Logger

  @candidates_per_pass 500

  # The enrichment-log columns the fold reads, in the order the aggregate
  # names them (`s_<col>`). The log keeps the worker's internal names.
  @history_cols ~w(enriched_at worker domain ctl_tld ctl_issuer ctl_subdomain_count ctl_subdomains
    dns_a dns_aaaa dns_mx dns_txt dns_cname dns_dmarc dns_bimi dns_dkim dns_ptr dns_ms_enterprise
    http_status http_response_time http_blocked http_content_type http_tech http_apps http_language
    http_title http_meta_description http_pages http_emails http_error http_h1 http_observed
    business_model industry classification_confidence http_schema_type http_og_type
    bgp_ip bgp_asn_number bgp_asn_org bgp_asn_country bgp_asn_prefix inferred_country
    http_country_evidence http_country_evidence_src rdap_registrant_country
    rdap_domain_created_at rdap_domain_expires_at rdap_domain_updated_at
    rdap_registrar rdap_registrar_iana_id rdap_nameservers rdap_status
    tranco_rank majestic_rank majestic_ref_subnets is_malware is_phishing is_disposable_email is_junk
    estimated_revenue estimated_employees revenue_confidence revenue_evidence
    classification_source pipeline_version http_fingerprint
    http_phone http_address http_social_links http_company_id http_nav_links http_shopify_app_handles
    http_etag http_last_modified http_body_simhash)

  # Nullable history columns and their inner type: an "absent" value on a
  # synthetic row must be a typed NULL, not '', or the fold's `IS NOT NULL`
  # rules would take it for a measurement.
  @history_nullable %{
    "ctl_subdomain_count" => "Int32", "http_status" => "Int32", "http_response_time" => "Int32",
    "classification_confidence" => "Float32", "revenue_confidence" => "Float32",
    "rdap_domain_created_at" => "DateTime", "rdap_domain_expires_at" => "DateTime",
    "rdap_domain_updated_at" => "DateTime",
    "tranco_rank" => "Int32", "majestic_rank" => "Int32", "majestic_ref_subnets" => "Int32"
  }

  # Columns only a crawl that reached the site (2xx-3xx) can fill. They live
  # on the "verified" synthetic row; the "latest" row leaves them blank so
  # `argMaxIf(col, ts, status BETWEEN 200 AND 399)` cannot pick it.
  @verified_cols ~w(http_status http_response_time http_blocked http_content_type http_tech http_apps
    http_language http_title http_meta_description http_pages http_h1 http_schema_type http_og_type is_junk
    http_fingerprint http_phone http_address http_social_links http_company_id http_nav_links http_shopify_app_handles
    http_etag http_last_modified http_body_simhash)

  # How a compiled `businesses` row reads back as a history row (the
  # synthetic leg). Columns absent here read as the same name.
  @from_business %{
    "worker" => "''",
    "ctl_subdomains" => "arrayStringConcat(ctl_subdomains, '|')",
    "dns_a" => "arrayStringConcat(dns_a, '|')",
    "dns_aaaa" => "''",
    "dns_mx" => "arrayStringConcat(dns_mx, '|')",
    "dns_txt" => "''",
    "dns_cname" => "''",
    "dns_ptr" => "''",
    "dns_ms_enterprise" => "''",
    "http_response_time" => "http_response_ms",
    "http_content_type" => "''",
    "http_tech" => "arrayStringConcat(http_tech, '|')",
    "http_apps" => "''",
    "http_pages" => "arrayStringConcat(http_pages_found, '|')",
    "http_emails" => "arrayStringConcat(http_emails, '|')",
    "business_model" => "estimated_business_model",
    "industry" => "estimated_industry",
    "classification_confidence" => "estimated_business_model_confidence",
    "http_og_type" => "''",
    "bgp_ip" => "''",
    "bgp_asn_number" => "bgp_asn",
    "bgp_asn_country" => "bgp_country",
    "bgp_asn_prefix" => "''",
    "inferred_country" => "estimated_country",
    "http_country_evidence" =>
      "if(estimated_country_evidence = '' OR estimated_country_evidence LIKE 'rdap:%' OR estimated_country_evidence LIKE 'tld:%', '', substring(estimated_country_evidence, position(estimated_country_evidence, ':') + 1))",
    "http_country_evidence_src" =>
      "if(estimated_country_evidence = '' OR estimated_country_evidence LIKE 'rdap:%' OR estimated_country_evidence LIKE 'tld:%', '', substring(estimated_country_evidence, 1, position(estimated_country_evidence, ':') - 1))",
    "rdap_domain_created_at" => "rdap_created_at",
    "rdap_domain_expires_at" => "rdap_expires_at",
    "rdap_domain_updated_at" => "rdap_updated_at",
    "rdap_registrar_iana_id" => "''",
    "rdap_nameservers" => "arrayStringConcat(rdap_nameservers, '|')",
    "rdap_status" => "arrayStringConcat(rdap_status, '|')",
    "is_malware" => "''",
    "is_phishing" => "''",
    "is_disposable_email" => "''",
    "is_junk" => "estimated_junk",
    "revenue_confidence" => "estimated_revenue_confidence",
    "revenue_evidence" => "estimated_revenue_evidence",
    "classification_source" => "estimated_business_model_evidence",
    "pipeline_version" => "estimated_version",
    "http_fingerprint" => "toJSONString(map('hosts', http_script_domains))",
    "http_social_links" => "arrayStringConcat(http_social_links, '|')",
    "http_nav_links" => "arrayStringConcat(http_nav_links, '|')",
    "http_shopify_app_handles" => "arrayStringConcat(http_shopify_app_handles, '|')"
  }

  @doc false
  def history_cols, do: @history_cols

  @doc """
  Crawls that observed the site: a 2xx/3xx whose body was read, not a bot
  wall served as 200 (`http_observed` is set at insert time). Used by the
  tech fold and the stable-domain check so both agree on what counts.
  """
  def observed_sql(prefix \\ ""), do: "(#{prefix}http_status BETWEEN 200 AND 399 AND #{prefix}http_observed = 1)"

  # ── entry points ─────────────────────────────────────────────────────────

  @doc """
  Compile the window `[since, until)` into `businesses` and record the
  changes it produced in `changes_log`. Returns `{:ok, rows_written}`.

  A bounded slice (2026-08-05): once one pass timed out, an open-ended
  window faced a strictly larger batch at every retry and never succeeded
  again. The slice is the same size no matter how long the compactor was
  down.
  """
  @spec compact_businesses(integer(), integer() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def compact_businesses(since_unix, until_unix \\ nil) do
    scratch = "tmp_compiled_#{since_unix}_#{:erlang.unique_integer([:positive])}"

    result =
      with {:ok, _} <- Clickhouse.query_raw("DROP TABLE IF EXISTS #{scratch}", 60_000, background: true),
           {:ok, _} <- Clickhouse.query_raw(scratch_sql(scratch, since_unix, until_unix), 1_200_000, background: true),
           :ok <- record_changes(scratch),
           {:ok, _} <- Clickhouse.query_raw(move_sql(scratch), 600_000, background: true),
           {:ok, [[n]]} <- Clickhouse.query("SELECT count() FROM #{scratch}") do
        {:ok, to_count(n)}
      else
        {:ok, _} -> {:ok, 0}
        err -> err
      end

    Clickhouse.query_raw("DROP TABLE IF EXISTS #{scratch}", 60_000, background: true)
    result
  end

  # The fold lands in a scratch MergeTree so the diff and the insert read it
  # twice. MergeTree, not Memory: a Memory table of 20K wide rows is fine,
  # but a catch-up slice of a few hundred thousand is not, and MergeTree
  # costs nothing extra at this size.
  defp scratch_sql(scratch, since_unix, until_unix) do
    "CREATE TABLE #{scratch} ENGINE = MergeTree ORDER BY domain AS\n" <> fold_select_sql(since_unix, until_unix, 1190)
  end

  defp move_sql(scratch) do
    cols = Enum.join(Columns.insert_columns(), ", ")
    "INSERT INTO #{Tables.businesses()} (#{cols}) SELECT #{cols} FROM #{scratch}"
  end

  # A signal failure is logged, never fatal: derived data must not block
  # product freshness. Idempotent on retry: changes_log dedups identical rows.
  defp record_changes(scratch) do
    case Clickhouse.query_raw(Changes.detect_sql(scratch), 120_000, background: true) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[SIGNAL] changes_log write failed (compaction continues): #{inspect(reason) |> String.slice(0, 300)}")
        :ok
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

  @doc "Full `businesses` rebuild in one query, a repair tool (no change detection)."
  def rebuild_businesses_full, do: Clickhouse.query_raw(compact_sql(0, nil, 1790), 30 * 60_000, background: true)

  @doc "Rebuild one hash-shard of `businesses`, the memory-safe backfill unit (256 shards of ~90K domains)."
  def compact_shard(shard, total_shards),
    do: Clickhouse.query_raw(compact_sql_shard(shard, total_shards), 1_200_000, background: true)

  @doc "The compaction SQL for one shard, without running it (so a contract test can EXPLAIN it)."
  def compact_sql_shard_preview(shard \\ 0, total \\ 256), do: compact_sql_shard(shard, total)

  @compact_domains_max 2_000

  @doc "Recompact an explicit list of domains now, outside the time window. At most 2,000 per call."
  def compact_domains(domains) when is_list(domains) do
    domains =
      domains
      |> Enum.filter(&(is_binary(&1) and &1 != "" and not String.contains?(&1, ["'", "\\", "\n"])))
      |> Enum.uniq()
      |> Enum.take(@compact_domains_max)

    case domains do
      [] -> {:ok, 0}
      _ -> Clickhouse.query_raw(compact_sql_domains(domains), 1_200_000, background: true)
    end
  end

  @doc false
  def compact_sql_domains(domains) do
    lit = domains |> Enum.map(&"'#{&1}'") |> Enum.join(",")
    compact_sql_guarded("domain IN (#{lit})")
  end

  # The same table sources as the shard form, each carrying the guard.
  defp compact_sql_guarded(guard) do
    compact_sql(0)
    |> String.replace("FROM #{Tables.enrich_log()})", "FROM #{Tables.enrich_log()} WHERE #{guard})")
    |> String.replace(
      "FROM #{Tables.http_deep_log()} WHERE render_engine != 'failed'",
      "FROM #{Tables.http_deep_log()} WHERE #{guard} AND render_engine != 'failed'"
    )
    |> String.replace("FROM #{Tables.http_deep_prices()} GROUP BY", "FROM #{Tables.http_deep_prices()} WHERE #{guard} GROUP BY")
    |> String.replace("FROM #{Tables.news_items()} GROUP BY", "FROM #{Tables.news_items()} WHERE #{guard} GROUP BY")
    |> String.replace("FROM #{Tables.verified_facts()}\n", "FROM #{Tables.verified_facts()} WHERE #{guard}\n")
    |> String.replace("FROM #{Tables.http_contacts()} GROUP BY", "FROM #{Tables.http_contacts()} WHERE #{guard} GROUP BY")
    |> String.replace("FROM #{Tables.ctl_log()} GROUP BY", "FROM #{Tables.ctl_log()} WHERE #{guard} GROUP BY")
  end

  defp compact_sql_shard(shard, total) do
    # A set of DOMAINS, not a raw hash predicate: enrich_log is sorted by
    # (domain, enriched_at), so `domain IN (set)` granule-prunes the read.
    set = "SELECT domain FROM #{Tables.businesses()} WHERE cityHash64(domain) % #{total} = #{shard}"
    compact_sql_guarded("domain IN (#{set})")
  end

  @doc false
  def compact_sql_for_test(since_unix, until_unix \\ nil), do: compact_sql(since_unix, until_unix)

  # ── the fold ─────────────────────────────────────────────────────────────

  @doc "The WITH scalars every form of the fold needs: the catalog and its alias map."
  def catalog_with do
    {from, to} = LS.Tech.Catalog.alias_arrays()

    """
    (SELECT groupUniqArray(name) FROM #{Tables.tech_catalog()}) AS _catalog,
         (SELECT groupUniqArray(name) FROM #{Tables.tech_catalog()} WHERE ecosystem != '') AS _apps_catalog,
         CAST(#{lit(from)}, 'Array(String)') AS _alias_from,
         CAST(#{lit(to)}, 'Array(String)') AS _alias_to\
    """
  end

  defp lit(list), do: "[" <> Enum.map_join(list, ", ", &"'#{String.replace(&1, "'", "\\'")}'") <> "]"

  @doc false
  def compact_sql(since_unix, until_unix \\ nil, max_s \\ 1190) do
    cols = Enum.join(Columns.insert_columns(), ", ")
    "INSERT INTO #{Tables.businesses()} (#{cols})\n" <> fold_select_sql(since_unix, until_unix, max_s)
  end

  @doc false
  def fold_select_sql(since_unix, until_unix \\ nil, max_s \\ 1190) do
    enrich_log = Tables.enrich_log()
    deep_log = Tables.http_deep_log()
    upper = if until_unix, do: " AND enriched_at < toDateTime(#{until_unix})", else: ""

    # The same bounded domain set scopes BOTH sides of every join (2026-08-05:
    # an unscoped join side materialised a whole table as a hash table).
    domain_set =
      """
      SELECT domain FROM #{enrich_log} WHERE enriched_at >= toDateTime(#{since_unix})#{upper}
      UNION DISTINCT
      SELECT domain FROM #{Tables.http_deep_state()} WHERE enriched_at >= toDateTime(#{since_unix})#{upper}
      UNION DISTINCT
      SELECT domain FROM #{Tables.verified_facts()} WHERE fetched_at >= toDateTime(#{since_unix})#{String.replace(upper, "enriched_at", "fetched_at")}
      """

    # Two scalar sets, computed once per pass:
    #   _touched    every domain any pipeline wrote in the window;
    #   _candidates window domains with no `businesses` row yet that could
    #               qualify one only through a block or a 401/403/429, with
    #               no classified crawl in the window (see history_rows_sql/2).
    #               Capped: this leg is the pass's variable cost.
    touched =
      if since_unix > 0 do
        """
        WITH #{catalog_with()},
             (SELECT groupUniqArray(domain) FROM (#{domain_set})) AS _touched,
             (SELECT groupUniqArray(domain) FROM (
               SELECT domain FROM #{enrich_log}
               WHERE enriched_at >= toDateTime(#{since_unix})#{upper}
                 AND domain NOT IN (SELECT domain FROM #{Tables.businesses()}
                                    WHERE domain IN (SELECT domain FROM #{enrich_log}
                                                     WHERE enriched_at >= toDateTime(#{since_unix})#{upper}))
               GROUP BY domain
               HAVING max(business_model != '') = 0
                  AND max(http_blocked != '' OR http_status IN (401, 403, 429)) = 1
               LIMIT #{@candidates_per_pass})) AS _candidates
        """
      else
        "WITH #{catalog_with()}\n"
      end

    # A rebuild aggregates whole tables and must be allowed to spill; the
    # incremental fold aggregates ~100K rows and spilling on that wrote 749
    # files for 36 MB (2026-09-07). Both thresholds off for the incremental form.
    spill = if since_unix > 0, do: 0, else: 1_500_000_000
    spill_ratio = if since_unix > 0, do: 0, else: 0.5
    join_scope = if since_unix > 0, do: " WHERE domain IN (SELECT arrayJoin(_touched))", else: ""

    # The deep side reads only SUCCESSFUL rows: a failed attempt is a fact
    # about the crawl, not the business, and must never erase a catalogue.
    depth_scope =
      if since_unix > 0,
        do: "WHERE render_engine != 'failed' AND domain IN (SELECT arrayJoin(_touched))",
        else: "WHERE render_engine != 'failed'"

    """
    #{touched}SELECT
      #{Columns.fold_select()}
    FROM (
      SELECT s_domain AS domain,
        min(s_first_seen) AS first_seen,
        max(s_enriched_at) AS as_of,
        maxIf(s_enriched_at, s_http_status BETWEEN 200 AND 399) AS last_verified_at,
        min(coalesce(s_http_first_seen, if(s_http_status BETWEEN 200 AND 399, s_enriched_at, NULL))) AS http_first_seen_at,
        argMax(s_worker, s_enriched_at) AS last_worker,
        max(s_http_status BETWEEN 200 AND 399) AS crawlable,
        argMaxIf(s_http_status, s_enriched_at, s_http_status IS NOT NULL) AS last_http_status,
        maxIf(s_enriched_at, s_http_error != '') AS _err_at,
        if(_err_at > last_verified_at,
           argMaxIf(s_http_error, s_enriched_at, s_http_error != ''), '') AS last_http_error,
        maxIf(s_enriched_at, s_http_blocked != '') AS _blk_at,
        if(_blk_at > last_verified_at,
           argMaxIf(s_http_blocked, s_enriched_at, s_http_blocked != ''), '') AS last_http_blocked,
        argMax(s_dns_alive, s_enriched_at) AS dns_alive,
        argMaxIf(s_http_status, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_status,
        argMaxIf(s_http_response_time, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_response_time,
        argMaxIf(s_http_blocked, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_blocked,
        argMaxIf(s_http_content_type, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS http_content_type,
        /* Only crawls that observed the site (observed_sql/1): a bot wall
           served as 200 used to replace a real 40-technology list with
           "Cloudflare" (2026-09-06). */
        argMaxIf(s_http_tech, s_enriched_at, #{observed_sql("s_")}) AS http_tech,
        argMaxIf(s_http_apps, s_enriched_at, #{observed_sql("s_")}) AS http_apps,
        argMaxIf(s_http_fingerprint, s_enriched_at, #{observed_sql("s_")} AND s_http_fingerprint != '') AS http_fingerprint,
        argMaxIf(s_http_shopify_app_handles, s_enriched_at, #{observed_sql("s_")}) AS http_shopify_app_handles,
        /* Validators and the text fingerprint: the newest observed fetch
           that carried one (2026-10-01). */
        argMaxIf(s_http_etag, s_enriched_at, #{observed_sql("s_")} AND s_http_etag != '') AS http_etag,
        argMaxIf(s_http_last_modified, s_enriched_at, #{observed_sql("s_")} AND s_http_last_modified != '') AS http_last_modified,
        argMaxIf(s_http_body_simhash, s_enriched_at, #{observed_sql("s_")} AND s_http_body_simhash != 0) AS http_body_simhash,
        /* Every page fact takes the observed guard (data model v2): a bot
           wall served as 200 carried "Just a moment..." into http_title and
           the next real crawl then recorded a title change. */
        argMaxIf(s_http_language, s_enriched_at, #{observed_sql("s_")}) AS http_language,
        argMaxIf(s_http_title, s_enriched_at, #{observed_sql("s_")}) AS http_title,
        argMaxIf(s_http_meta_description, s_enriched_at, #{observed_sql("s_")}) AS http_meta_description,
        argMaxIf(s_http_pages, s_enriched_at, #{observed_sql("s_")}) AS http_pages,
        argMaxIf(s_http_h1, s_enriched_at, #{observed_sql("s_")}) AS http_h1,
        argMaxIf(s_http_schema_type, s_enriched_at, #{observed_sql("s_")}) AS http_schema_type,
        argMaxIf(s_http_og_type, s_enriched_at, #{observed_sql("s_")}) AS http_og_type,
        argMaxIf(s_http_phone, s_enriched_at, s_http_phone != '') AS http_phone,
        argMaxIf(s_http_address, s_enriched_at, s_http_address != '') AS http_address,
        argMaxIf(s_http_company_id, s_enriched_at, s_http_company_id != '') AS http_company_id,
        argMaxIf(splitByChar('|', s_http_nav_links), s_enriched_at, s_http_nav_links != '') AS http_nav_links_arr,
        /* Union rules (2026-10-01): a crawl that finds one address or one
           profile link must not erase the two an earlier crawl found. */
        arraySlice(arrayDistinct(arrayFilter(x -> x != '',
          arrayFlatten(groupArray(splitByChar('|', s_http_emails))))), 1, 20) AS http_emails_all,
        arraySlice(arrayDistinct(arrayFilter(x -> x != '',
          arrayFlatten(groupArray(splitByChar('|', s_http_social_links))))), 1, 20) AS http_social_links,
        argMaxIf(s_business_model, s_enriched_at, s_business_model != '') AS business_model,
        argMaxIf(s_industry, s_enriched_at, s_business_model != '') AS industry,
        argMaxIf(s_classification_confidence, s_enriched_at, s_business_model != '') AS classification_confidence,
        argMaxIf(s_bgp_ip, s_enriched_at, s_bgp_asn_number != '') AS bgp_ip,
        argMaxIf(s_bgp_asn_number, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_number,
        argMaxIf(s_bgp_asn_org, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_org,
        argMaxIf(s_bgp_asn_country, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_country,
        argMaxIf(s_bgp_asn_prefix, s_enriched_at, s_bgp_asn_number != '') AS bgp_asn_prefix,
        maxIf(s_enriched_at, s_bgp_asn_number != '') AS bgp_last_seen_at,
        argMaxIf(s_rdap_domain_created_at, s_enriched_at, s_rdap_registrar != '') AS rdap_domain_created_at,
        argMaxIf(s_rdap_domain_expires_at, s_enriched_at, s_rdap_registrar != '') AS rdap_domain_expires_at,
        argMaxIf(s_rdap_domain_updated_at, s_enriched_at, s_rdap_registrar != '') AS rdap_domain_updated_at,
        argMaxIf(s_rdap_registrar, s_enriched_at, s_rdap_registrar != '') AS rdap_registrar,
        argMaxIf(s_rdap_registrar_iana_id, s_enriched_at, s_rdap_registrar != '') AS rdap_registrar_iana_id,
        argMaxIf(s_rdap_nameservers, s_enriched_at, s_rdap_registrar != '') AS rdap_nameservers,
        argMaxIf(s_rdap_status, s_enriched_at, s_rdap_registrar != '') AS rdap_status,
        maxIf(s_enriched_at, s_rdap_registrar != '') AS rdap_last_seen_at,
        argMaxIf(s_ctl_tld, s_enriched_at, s_ctl_issuer != '') AS ctl_tld,
        argMaxIf(s_ctl_issuer, s_enriched_at, s_ctl_issuer != '') AS ctl_issuer,
        maxIf(s_enriched_at, s_ctl_issuer != '') AS ctl_last_seen_at,
        /* Subdomains are a UNION over every certificate we have seen for the
           domain (2026-09-06), capped at 300 names. */
        arraySlice(arrayDistinct(arrayFilter(x -> x != '',
          arrayFlatten(groupArray(splitByChar('|', s_ctl_subdomains))))), 1, 300) AS _subs_hist,
        /* The BEST-EVIDENCED estimate wins, newest on ties (2026-09-07). */
        argMaxIf(s_estimated_revenue, (s_revenue_confidence, s_enriched_at), s_estimated_revenue != '') AS estimated_revenue,
        argMaxIf(s_estimated_employees, (s_revenue_confidence, s_enriched_at), s_estimated_revenue != '') AS estimated_employees,
        argMaxIf(s_revenue_confidence, (s_revenue_confidence, s_enriched_at), s_estimated_revenue != '') AS revenue_confidence,
        argMaxIf(s_revenue_evidence, (s_revenue_confidence, s_enriched_at), s_estimated_revenue != '') AS revenue_evidence,
        argMaxIf(s_dns_a, s_enriched_at, s_dns_a != '') AS dns_a,
        argMaxIf(s_dns_aaaa, s_enriched_at, s_dns_aaaa != '') AS dns_aaaa,
        argMaxIf(s_dns_mx, s_enriched_at, s_dns_mx != '') AS dns_mx,
        argMaxIf(s_dns_txt, s_enriched_at, s_dns_txt != '') AS dns_txt,
        argMaxIf(s_dns_cname, s_enriched_at, s_dns_cname != '') AS dns_cname,
        argMaxIf(s_dns_dmarc, s_enriched_at, s_dns_mx != '') AS dns_dmarc,
        argMaxIf(s_dns_bimi, s_enriched_at, s_dns_mx != '') AS dns_bimi,
        argMaxIf(s_dns_dkim, s_enriched_at, s_dns_mx != '') AS dns_dkim,
        argMaxIf(s_dns_ptr, s_enriched_at, s_dns_ptr != '') AS dns_ptr,
        argMaxIf(s_dns_ms_enterprise, s_enriched_at, s_dns_mx != '') AS dns_ms_enterprise,
        maxIf(s_enriched_at, s_dns_a != '') AS dns_last_seen_at,
        argMaxIf(s_classification_source, s_enriched_at, s_business_model != '') AS classification_source,
        argMaxIf(s_pipeline_version, s_enriched_at, s_pipeline_version != '') AS pipeline_version,
        argMaxIf(s_inferred_country, s_enriched_at, s_inferred_country != '') AS inferred_country,
        argMaxIf(s_http_emails, s_enriched_at, s_http_emails != '') AS http_emails,
        argMaxIf(s_http_country_evidence, s_enriched_at, s_http_country_evidence != '') AS http_country_evidence,
        argMaxIf(s_http_country_evidence_src, s_enriched_at, s_http_country_evidence != '') AS http_country_evidence_src,
        argMaxIf(s_rdap_registrant_country, s_enriched_at, s_rdap_registrant_country != '') AS rdap_registrant_country,
        argMaxIf(s_tranco_rank, s_enriched_at, s_tranco_rank IS NOT NULL) AS tranco_rank,
        argMaxIf(s_majestic_rank, s_enriched_at, s_majestic_rank IS NOT NULL) AS majestic_rank,
        argMaxIf(s_majestic_ref_subnets, s_enriched_at, s_majestic_ref_subnets IS NOT NULL) AS majestic_ref_subnets,
        if(max(s_is_malware = 'true'), 'true', '') AS is_malware,
        if(max(s_is_phishing = 'true'), 'true', '') AS is_phishing,
        /* Junk follows the NEWEST successful fetch: a parked domain that
           comes back to life must clear the flag. */
        argMaxIf(s_is_junk, s_enriched_at, s_http_status BETWEEN 200 AND 399) AS is_junk
      FROM (#{history_rows_sql(since_unix, until_unix)})
      GROUP BY s_domain
      /* Who becomes a business (2026-10-03): any site we observed with a
         title and no junk verdict, classified or not. From 09-07 to 10-03
         only classified sites (0.6 or better) qualified, and 446K first
         fetches a day returned a real page that was then thrown away: a
         Kennebunkport shop, a dive school, a photographer, all abstained on
         by the classifier. They are kept now, with an empty model, and the
         stored page blocks let the classifier revisit them without a refetch.
         Walled sites keep their row on a mail server alone, for the browser lane. */
      HAVING (is_malware = '' AND is_phishing = '')
         AND ((business_model != '' AND crawlable)
              OR (crawlable AND http_title != '' AND is_junk = '')
              OR ((last_http_blocked != '' OR last_http_status IN (401, 403, 429)) AND dns_mx != ''))
    ) h
    LEFT JOIN (
      SELECT
        domain,
        max(enriched_at) AS enriched_at_newest,
        argMax(render_engine, enriched_at) AS render_engine,
        /* Numerics are Nullable BY DESIGN: NULL = "could not look", 0 =
           "looked, found none". argMaxIf(col, ts, col IS NOT NULL) keeps the
           last MEASURED value, so a blind spot never erases. */
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
        /* Qualified (s0.) on purpose: the bare name resolves to the alias
           two lines up and becomes a nested aggregate (Code 184). */
        maxIf(s0.enriched_at, s0.product_count IS NOT NULL) AS shop_at,
        argMaxIf(job_count, enriched_at, job_count IS NOT NULL) AS job_count,
        maxIf(s0.enriched_at, s0.job_count IS NOT NULL) AS hr_at,
        argMaxIf(seo_score, enriched_at, seo_score IS NOT NULL) AS seo_score,
        argMaxIf(seo_word_count, enriched_at, seo_word_count IS NOT NULL) AS seo_word_count,
        argMaxIf(seo_alt_ratio, enriched_at, seo_alt_ratio IS NOT NULL) AS seo_alt_ratio,
        argMaxIf(perf_lcp_ms, enriched_at, perf_lcp_ms IS NOT NULL) AS perf_lcp_ms,
        argMaxIf(perf_cls, enriched_at, perf_cls IS NOT NULL) AS perf_cls,
        argMaxIf(perf_ttfb_ms, enriched_at, perf_ttfb_ms IS NOT NULL) AS perf_ttfb_ms,
        argMaxIf(product_types, enriched_at, product_types != '') AS product_types,
        argMaxIf(apps_deep, enriched_at, apps_deep != '') AS apps_deep,
        argMaxIf(shop_theme, enriched_at, shop_theme != '') AS shop_theme,
        argMaxIf(shop_theme_store_id, enriched_at, shop_theme_store_id IS NOT NULL) AS shop_theme_store_id,
        argMaxIf(shop_currency, enriched_at, shop_currency != '') AS shop_currency,
        argMaxIf(shop_locales, enriched_at, shop_locales IS NOT NULL) AS shop_locales,
        argMaxIf(shopify_plus, enriched_at, shopify_plus IS NOT NULL) AS shopify_plus,
        argMaxIf(sitemap_urls, enriched_at, sitemap_urls IS NOT NULL) AS sitemap_urls,
        argMaxIf(sitemap_products, enriched_at, sitemap_products IS NOT NULL) AS sitemap_products,
        argMaxIf(sitemap_blog, enriched_at, sitemap_blog IS NOT NULL) AS sitemap_blog,
        argMaxIf(sitemap_children, enriched_at, sitemap_children IS NOT NULL) AS sitemap_children,
        argMaxIf(sitemap_lastmod, enriched_at, sitemap_lastmod IS NOT NULL) AS sitemap_lastmod,
        argMaxIf(sitemap_hash, enriched_at, sitemap_hash IS NOT NULL) AS sitemap_hash,
        argMaxIf(depth_estimated_revenue, enriched_at, depth_estimated_revenue != '') AS d_est_revenue,
        argMaxIf(depth_estimated_employees, enriched_at, depth_estimated_revenue != '') AS d_est_employees,
        argMaxIf(depth_revenue_confidence, enriched_at, depth_estimated_revenue != '') AS d_rev_confidence,
        argMaxIf(depth_revenue_evidence, enriched_at, depth_estimated_revenue != '') AS d_rev_evidence,
        argMaxIf(ats_platform, enriched_at, ats_platform != '') AS ats_platform,
        argMaxIf(job_departments, enriched_at, job_departments != '') AS job_departments,
        argMaxIf(job_locations, enriched_at, job_locations != '') AS job_locations,
        argMaxIf(seo_issues, enriched_at, seo_issues != '') AS seo_issues,
        argMaxIf(mission, enriched_at, mission != '') AS mission,
        argMaxIf(hq_location, enriched_at, hq_location != '') AS hq_location
      FROM (SELECT * FROM #{deep_log} #{depth_scope}) AS s0
      GROUP BY domain
    ) s ON h.domain = s.domain
    LEFT JOIN (SELECT domain, count() AS pricing_points FROM #{Tables.http_deep_prices()}#{join_scope} GROUP BY domain) p
           ON h.domain = p.domain
    LEFT JOIN (SELECT domain, count() AS news_count, max(amount_usd) AS last_funding_usd, max(seen_at) AS last_at
               FROM #{Tables.news_items()}#{join_scope} GROUP BY domain) n ON h.domain = n.domain
    LEFT JOIN (#{verified_sql(join_scope)}) v ON h.domain = v.domain
    LEFT JOIN (
      /* Certificates the 7-day gate suppressed (LS.Cluster.CrawlDedup):
         their subdomains join the union too. */
      SELECT domain,
        arraySlice(arrayDistinct(arrayFilter(x -> x != '',
          arrayFlatten(groupArray(splitByChar('|', ctl_subdomains))))), 1, 300) AS subs
      FROM #{Tables.ctl_log()}#{join_scope} GROUP BY domain
    ) c ON h.domain = c.domain
    LEFT JOIN (
      /* Addresses the deep pass found on the contact, legal, about and
         pricing pages, with the page each came from. */
      SELECT domain, groupUniqArray(20)(email) AS emails, groupUniqArray(source_page) AS pages
      FROM #{Tables.http_contacts()}#{join_scope} GROUP BY domain
    ) ct ON h.domain = ct.domain
    SETTINGS max_bytes_before_external_group_by = #{spill}, max_bytes_ratio_before_external_group_by = #{spill_ratio},
             max_threads = 2, join_use_nulls = 1, max_execution_time = #{max_s}
    """
  end

  @doc """
  The rows the fold aggregates for one pass, as `s_*` columns: the window's
  new rows, each touched business replayed as two synthetic history rows,
  and the whole history of the window's candidates. See the 2026-09-07 note
  on `LS.Clickhouse` for the measurements behind the shape.
  """
  def history_rows_sql(since_unix, until_unix \\ nil)

  def history_rows_sql(0, _), do: history_leg(Tables.enrich_log())

  def history_rows_sql(since_unix, until_unix) do
    upper = if until_unix, do: " AND enriched_at < toDateTime(#{until_unix})", else: ""
    window = "enriched_at >= toDateTime(#{since_unix})#{upper}"
    enrich_log = Tables.enrich_log()

    Enum.join(
      [
        history_leg("#{enrich_log} WHERE #{window}"),
        history_leg("#{enrich_log} WHERE domain IN (SELECT arrayJoin(_candidates)) AND enriched_at < toDateTime(#{since_unix})"),
        synthetic_leg()
      ],
      "\n      UNION ALL\n      "
    )
  end

  # A real history leg: every column as itself plus the carried values.
  defp history_leg(from) do
    cols = Enum.map_join(@history_cols, ", ", &"#{&1} AS s_#{&1}")

    "SELECT #{cols}, enriched_at AS s_first_seen, (dns_a != '' OR dns_cname != '') AS s_dns_alive, " <>
      "CAST(NULL, 'Nullable(DateTime)') AS s_http_first_seen FROM #{from}"
  end

  # The compiled rows, replayed as history: one read of `businesses` for the
  # touched set (newest version by compiled_at, not FINAL), then ARRAY JOIN
  # fans each row out into its verified row (leg 1, crawlable rows only) and
  # its latest row (leg 2). `domain` stays on both legs: blank it and the row
  # folds into an empty-string group (2,082 businesses dropped, 2026-09-07).
  defp synthetic_leg do
    # ifNull: a Nullable s_enriched_at would make every argMaxIf result
    # Nullable, and splitByChar on a Nullable String is a Nullable Array,
    # which ClickHouse refuses (Code 43, found on the local harness).
    verified = %{
      "enriched_at" => "ifNull(http_last_seen_at, http_last_checked_at)",
      "domain" => "domain",
      "http_status" => "200",
      "http_blocked" => "''",
      "http_observed" => "1"
    }

    latest = %{
      "enriched_at" => "http_last_checked_at",
      "http_status" => "if(http_status BETWEEN 200 AND 399, NULL, http_status)",
      "http_error" => "http_error",
      "http_blocked" => "http_blocked",
      "http_observed" => "0"
    }

    cols =
      Enum.map_join(@history_cols, ", ", fn col ->
        base = Map.get(@from_business, col, col)
        v = Map.get_lazy(verified, col, fn -> if(col in @verified_cols, do: base, else: blank(col)) end)
        l = Map.get_lazy(latest, col, fn -> if(col in @verified_cols, do: blank(col), else: base) end)
        expr = if v == l, do: v, else: "if(leg = 1, #{v}, #{l})"
        "#{expr} AS s_#{col}"
      end)

    """
    SELECT #{cols}, ctl_first_seen_at AS s_first_seen, toUInt8(notEmpty(dns_a)) AS s_dns_alive, http_first_seen_at AS s_http_first_seen
      FROM (SELECT * FROM #{Tables.businesses()} WHERE domain IN (SELECT arrayJoin(_touched)) ORDER BY compiled_at DESC LIMIT 1 BY domain)
      ARRAY JOIN if(http_crawlable = 1, [1, 2], [2]) AS leg
    """
  end

  defp blank("http_observed"), do: "0"
  defp blank("http_body_simhash"), do: "toUInt64(0)"

  defp blank(col) do
    case Map.fetch(@history_nullable, col) do
      {:ok, t} -> "CAST(NULL, 'Nullable(#{t})')"
      :error -> "''"
    end
  end

  # Pipeline 3's contribution: one verified revenue and one verified
  # employees value per domain, chosen by source PRECEDENCE (audited filings
  # beat registries beat crowd data), never by recency.
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
      argMaxIf(value, fetched_at, fact = 'mission') AS mission_summary,
      argMaxIf(value, fetched_at, fact = 'hq') AS hq,
      argMaxIf(value, fetched_at, fact = 'industry') AS industry,
      toUInt16OrNull(substring(argMaxIf(value, fetched_at, fact = 'inception'), 1, 4)) AS founded_year,
      max(fetched_at) AS verified_at
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
        /* newest value per (domain, fact, source); LIMIT 1 BY, not
           GROUP BY+argMax (nested aggregate, Code 184, the 2026-08-19 freeze).
           The largest value wins on ties: a subsidiary is never bigger than
           its parent (2026-09-06). */
        SELECT domain, fact, source, value, fetched_at
        FROM #{Tables.verified_facts()}#{join_scope}
        ORDER BY fetched_at DESC, toFloat64OrZero(value) DESC
        LIMIT 1 BY domain, fact, source
      )
    )
    GROUP BY domain
    """
  end

  # ── stable domains ───────────────────────────────────────────────────────

  @doc """
  Domains whose newest crawl in the window looks exactly like the compiled
  row we already had: same title, published tech list and status, with the
  days since the previous check. Feeds the crawl gate's stable ring (28-35
  days instead of 7, 2026-09-09) or, when the previous check was itself
  25+ days back (so it was already unchanged once), the dormant ring
  (60-90 days, 2026-10-01). Only
  observed 2xx/3xx crawls count, and the window's raw tech list goes
  through the same catalog map as the fold, so a store whose unknown
  handles the catalog drops is still "unchanged".
  """
  def stable_domains(since_unix, until_unix) do
    case Clickhouse.query_raw(stable_domains_sql(since_unix, until_unix), 120_000, background: true) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [d, gap] -> {d, to_int(gap)} end)}
      err -> err
    end
  end

  @doc """
  Domains with a change recorded in the window, subdomain churn excluded.
  They go into the crawl gate's hot ring (back on the 7-day schedule).
  """
  def changed_domains(since_unix, until_unix) do
    sql = """
    SELECT DISTINCT domain FROM #{Tables.changes_log()}
    WHERE changed_at >= toDateTime(#{int(since_unix)}) AND changed_at < toDateTime(#{int(until_unix)})
      AND field != 'ctl_subdomains'
    SETTINGS max_execution_time = 30, max_threads = 2
    """

    case Clickhouse.query_raw(sql, 40_000, background: true) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [d] -> d end)}
      err -> err
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: (case Integer.parse(n) do {v, _} -> v; _ -> 0 end)
  defp to_int(_), do: 0

  @doc false
  def stable_domains_sql(since_unix, until_unix) do
    window = "enriched_at >= toDateTime(#{int(since_unix)}) AND enriched_at < toDateTime(#{int(until_unix)})"
    enrich_log = Tables.enrich_log()

    """
    WITH #{catalog_with()}
    SELECT n.domain, dateDiff('day', ifNull(o.http_last_checked_at, n.at), n.at) AS gap_days
    FROM (
      SELECT domain, max(enriched_at) AS at,
             argMax(http_title, enriched_at) AS title,
             arraySort(arrayDistinct(arrayFilter(x -> x != '' AND has(_catalog, x),
               arrayMap(x -> transform(x, _alias_from, _alias_to, x),
                 arrayConcat(splitByChar('|', argMax(http_tech, enriched_at)), splitByChar('|', argMax(http_apps, enriched_at))))))) AS tech,
             argMax(http_status, enriched_at) AS status
      FROM #{enrich_log}
      WHERE #{window} AND #{observed_sql("")}
      GROUP BY domain
    ) AS n
    INNER JOIN (
      SELECT domain, http_title, arraySort(http_tech) AS tech_sorted, http_status, tranco_rank, http_last_checked_at
      FROM #{Tables.businesses()}
      WHERE domain IN (SELECT domain FROM #{enrich_log} WHERE #{window})
      ORDER BY compiled_at DESC
      LIMIT 1 BY domain
    ) AS o USING (domain)
    WHERE n.title = o.http_title AND n.tech = o.tech_sorted AND n.status = o.http_status
      AND (o.tranco_rank IS NULL OR o.tranco_rank > 100000)
    SETTINGS max_execution_time = 115, max_threads = 2
    """
  end

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0

  @doc """
  Backfill one hash-shard of `changes_log` from crawl history: tech added
  and removed between consecutive observed crawls, through the catalog map.
  Run only when the box is otherwise quiet.
  """
  def backfill_changes_shard(shard, total) do
    guard = "cityHash64(domain) % #{total} = #{shard}"

    sql = """
    WITH #{catalog_with()}
    INSERT INTO #{Tables.changes_log()} (domain, field, change, value, prev_value, changed_at)
    SELECT domain, 'http_tech', sig.1, sig.2, '', at FROM (
      SELECT domain, enriched_at AS at,
             arrayFilter(x -> x != '' AND has(_catalog, x), arrayMap(x -> transform(x, _alias_from, _alias_to, x), arrayConcat(splitByChar('|', http_tech), splitByChar('|', http_apps)))) AS cur_t,
             arrayFilter(x -> x != '' AND has(_catalog, x), arrayMap(x -> transform(x, _alias_from, _alias_to, x), arrayConcat(splitByChar('|', lagInFrame(http_tech, 1, '') OVER w), splitByChar('|', lagInFrame(http_apps, 1, '') OVER w)))) AS prev_t,
             lagInFrame(http_tech, 1, '') OVER w AS prev_raw
      FROM #{Tables.enrich_log()}
      WHERE #{guard} AND #{observed_sql()} AND http_tech != ''
        AND domain IN (SELECT domain FROM #{Tables.businesses()} WHERE #{guard})
      WINDOW w AS (PARTITION BY domain ORDER BY enriched_at ROWS BETWEEN 1 PRECEDING AND 1 PRECEDING)
    )
    ARRAY JOIN arrayConcat(
      arrayMap(x -> ('added', x),   arrayFilter(x -> NOT has(prev_t, x), cur_t)),
      arrayMap(x -> ('removed', x), arrayFilter(x -> NOT has(cur_t, x), prev_t))
    ) AS sig
    WHERE prev_raw != ''
    SETTINGS max_threads = 2, max_bytes_before_external_group_by = 1000000000
    """

    Clickhouse.query_raw(sql, 300_000)
  end
end
