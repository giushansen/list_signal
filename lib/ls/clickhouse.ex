defmodule LS.Clickhouse do
  @moduledoc "ClickHouse query interface for ListSignal web pages."

  @ch_url "http://127.0.0.1:8123/"
  @ch_db "ls"
  @timeout 10_000

  # ── Landing page ──

  def shopify_store_count do
    case query("SELECT count() FROM domains_current WHERE http_tech LIKE '%Shopify%'") do
      {:ok, [[count]]} -> count
      _ -> nil
    end
  end

  def sample_shopify_stores(limit \\ 6) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank
    FROM domains_current
    WHERE http_tech LIKE '%Shopify%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def recent_stores(limit \\ 20) do
    query("""
    SELECT domain, #{country_expr()} AS country, http_title, http_tech, enriched_at
    FROM domains_current
    WHERE http_tech LIKE '%Shopify%' AND http_title != ''
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
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank
    FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def stores_by_tech_ilike(search, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank
    FROM domains_current
    WHERE lower(http_tech) LIKE '%#{escape(String.downcase(search))}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def tech_store_count(tech_name) do
    case query("SELECT count() FROM domains_current WHERE http_tech LIKE '%#{escape(tech_name)}%'") do
      {:ok, [[count]]} -> count
      _ -> 0
    end
  end

  # ── Tech profile (rich) ──

  def stores_by_tech_full(tech_name, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank,
           http_response_time, http_language, rdap_registrar,
           rdap_domain_created_at, http_status, bgp_asn_org,
           dns_mx, http_emails, majestic_rank
    FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def stores_by_tech_full_ilike(search, limit \\ 100) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank,
           http_response_time, http_language, rdap_registrar,
           rdap_domain_created_at, http_status, bgp_asn_org,
           dns_mx, http_emails, majestic_rank
    FROM domains_current
    WHERE lower(http_tech) LIKE '%#{escape(String.downcase(search))}%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """)
  end

  def tech_stats(tech_name) do
    query("""
    SELECT
      count() AS total,
      avg(http_response_time) AS avg_response_time,
      countIf(http_status = 200) AS online_count,
      countIf(tranco_rank IS NOT NULL AND tranco_rank <= 100000) AS top_100k_count
    FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_title != ''
    """)
  end

  def tech_language_distribution(tech_name) do
    query("""
    SELECT http_language, count() AS cnt FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_language != ''
    GROUP BY http_language ORDER BY cnt DESC LIMIT 10
    """)
  end

  def tech_hosting_distribution(tech_name) do
    query("""
    SELECT bgp_asn_org, count() AS cnt FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND bgp_asn_org != ''
    GROUP BY bgp_asn_org ORDER BY cnt DESC LIMIT 10
    """)
  end

  def tech_registrar_distribution(tech_name) do
    query("""
    SELECT rdap_registrar, count() AS cnt FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND rdap_registrar != ''
    GROUP BY rdap_registrar ORDER BY cnt DESC LIMIT 10
    """)
  end

  def tech_co_occurring(tech_name) do
    query("""
    SELECT arrayJoin(splitByString('|', http_tech)) AS tech, count() AS cnt
    FROM domains_current
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
    SELECT count() FROM domains_current
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
    SELECT #{country_expr()} AS country, count() AS cnt FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND #{country_expr()} != ''
    GROUP BY country ORDER BY cnt DESC LIMIT 10
    """)
  end

  # ── Top / Ranking pages ──

  def top_stores_by_country(country_code, limit \\ 50) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank
    FROM domains_current
    WHERE http_tech LIKE '%Shopify%' AND #{country_expr()} = '#{escape(country_code)}' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  def top_stores_using_tech(tech_name, limit \\ 50) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank
    FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_tech LIKE '%Shopify%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  def top_stores_using_tech_in_country(tech_name, country_code, limit \\ 50) do
    query("""
    SELECT domain, http_title, http_tech, #{country_expr()} AS country, tranco_rank
    FROM domains_current
    WHERE http_tech LIKE '%#{escape(tech_name)}%' AND http_tech LIKE '%Shopify%'
      AND #{country_expr()} = '#{escape(country_code)}' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  # ── Directory / Hub pages ──

  def tech_directory do
    query("""
    SELECT arrayJoin(splitByString('|', http_tech)) AS tech, count() AS cnt
    FROM domains_current WHERE http_tech != ''
    GROUP BY tech HAVING cnt >= 5 ORDER BY cnt DESC LIMIT 500
    """)
  end

  def country_directory do
    query("""
    SELECT #{country_expr()} AS country, count() AS cnt FROM domains_current
    WHERE http_tech LIKE '%Shopify%' AND #{country_expr()} != ''
    GROUP BY country ORDER BY cnt DESC
    """)
  end

  # ── Sitemap ──

  def all_shopify_domains(limit \\ 49_000) do
    query("""
    SELECT domain FROM domains_current
    WHERE http_tech LIKE '%Shopify%' AND http_title != ''
    ORDER BY tranco_rank ASC NULLS LAST LIMIT #{limit}
    """)
  end

  def scan_rate_per_minute do
    case query("SELECT count() FROM enrichments WHERE enriched_at >= now() - INTERVAL 1 MINUTE") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def scan_rate_per_second do
    case query("SELECT count() / 60.0 FROM enrichments WHERE enriched_at >= now() - INTERVAL 1 MINUTE") do
      {:ok, [[rate]]} when is_number(rate) -> Float.round(rate / 1.0, 1)
      _ -> nil
    end
  end

  def stores_last_hour do
    case query("SELECT count() FROM enrichments WHERE enriched_at >= now() - INTERVAL 1 HOUR") do
      {:ok, [[count]]} when is_integer(count) -> count
      _ -> nil
    end
  end

  def shopify_stores_last_hour do
    case query("SELECT count() FROM enrichments WHERE enriched_at >= now() - INTERVAL 1 HOUR AND http_tech LIKE '%Shopify%'") do
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

  # ── Recrawl scheduler ──

  @doc """
  Fetch domains that need re-crawling based on tiered freshness.
  Digital businesses (Ecommerce, SaaS, Tool, Marketplace, Agency) → stale after `weekly_days`.
  Everything else → stale after `monthly_days`.
  Returns {:ok, [domain, ...]} or {:error, reason}.
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
    AND http_status IS NOT NULL
    ORDER BY tranco_rank ASC NULLS LAST
    LIMIT #{limit}
    """

    case query(sql) do
      {:ok, rows} -> {:ok, Enum.map(rows, fn [d] -> d end)}
      err -> err
    end
  end

  # ── Raw + Public ──

  def query_raw(sql) do
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact"
    case Req.post(url, body: sql, receive_timeout: @timeout) do
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: status, body: body}} -> {:error, "CH #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def escape_public(str), do: escape(str)

  # ── Private ──

  defp query(sql) do
    url = "#{@ch_url}?database=#{@ch_db}&default_format=JSONCompact"
    case Req.post(url, body: sql, receive_timeout: @timeout) do
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
