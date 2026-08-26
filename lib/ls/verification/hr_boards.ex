defmodule LS.Verification.HRBoards do
  @moduledoc """
  Pipeline 3: job-platform boards as standing assets.

  The Jobs enricher only sees a board when it happens to recrawl a company's
  careers page. This module makes boards durable and independently fresh:

    * `harvest_from_careers/0` extracts every board slug present in
      `biz_career` posting URLs into `hr_boards`. Re-run on every cycle, so
      newly enriched companies flow in without touching the workers.
    * `sync_stale/1` re-reads each known board straight from the platform's
      public JSON API (the same endpoints their own widgets call) and writes
      the fresh jobs into `biz_career` + a `biz_enrichment_log` row, which
      the compactor folds into `businesses`. Hiring data stays weekly-fresh
      even for companies we will not recrawl for months.

  Politeness: one board at a time, spaced by `@gap_ms`, hard cap per cycle.
  These are public unauthenticated APIs served from CDNs, but they are other
  people's infrastructure; the cap means a full sync spreads over days
  rather than looking like a scrape.
  """

  require Logger
  alias LS.Clickhouse

  @gap_ms 400
  @max_syncs_per_run 2_000
  @resync_after_days 7

  # slug extraction per platform, from the posting URLs we already store.
  @patterns [
    {"greenhouse", ~r{(?:job-boards|boards)\.greenhouse\.io/([a-z0-9_-]+)/}i},
    {"lever", ~r{jobs\.(?:eu\.)?lever\.co/([a-zA-Z0-9_-]+)/}},
    {"ashby", ~r{jobs\.ashbyhq\.com/([a-zA-Z0-9_-]+)/}},
    {"workable", ~r{apply\.workable\.com/([a-z0-9-]+)/}i},
    # Two shapes in the wild: jobs.smartrecruiters.com/{Co}/{id} public ads
    # and api.smartrecruiters.com/v1/companies/{Co}/postings/{id} API refs.
    {"smartrecruiters", ~r{smartrecruiters\.com/(?:v1/companies/)?([A-Za-z0-9]+)/}},
    {"recruitee", ~r{https?://([a-z0-9-]+)\.recruitee\.com}i},
    # Workday needs host AND site ({tenant}.wd{N} + career-site name); the
    # slug is stored as "tenant.wdN:Site". Some URLs carry a locale segment.
    {"workday",
     ~r"https?://([a-z0-9-]+\.wd[0-9]+)\.myworkdayjobs\.com/(?:[a-z]{2}-[A-Z]{2}/)?([A-Za-z0-9_-]+)/job/"i},
    {"personio", ~r{https?://([a-z0-9-]+)\.jobs\.personio\.(?:de|com)}},
    {"breezy", ~r{https?://([a-z0-9-]+)\.breezy\.hr}}
  ]

  @doc "SQL patterns exposed for the contract test: every pattern must extract from a real stored URL."
  def patterns, do: @patterns

  @doc false
  def harvest_sql_for_test(platform), do: harvest_sql(platform)

  # ── Harvest: biz_career URLs → hr_boards rows ─────────────────────────────

  def harvest_from_careers do
    total =
      Enum.reduce(@patterns, 0, fn {platform, _re}, acc ->
        case Clickhouse.query_raw(harvest_sql(platform), 120_000) do
          {:ok, _} -> acc + 1
          {:error, e} ->
            Logger.warning("[BOARDS] harvest #{platform} failed: #{inspect(e) |> String.slice(0, 120)}")
            acc
        end
      end)

    Logger.info("[BOARDS] harvest pass complete (#{total}/#{length(@patterns)} platforms)")
    :ok
  end

  # INSERT-SELECT entirely inside ClickHouse: no rows travel through the BEAM.
  # ReplacingMergeTree(last_synced) means re-harvesting an existing slug with
  # last_synced=0 loses to any synced row at merge time, so re-runs are free.
  #
  # The fan-out guard: a company's careers page embeds its own board, so a
  # legitimate referrer maps to 1 (rarely 2) slugs per platform. Job
  # aggregators reference dozens; without the guard `any(domain)` can hand a
  # company's board to the aggregator that linked it, and every later sync
  # writes that company's jobs under the aggregator's domain (measured
  # 2026-08-26: 415 of 416 greenhouse referrers were 1:1 — the guard costs
  # nothing and blocks the pollution as biz_career grows).
  defp harvest_sql(platform) do
    expr = slug_expr(platform)

    """
    INSERT INTO hr_boards (platform, slug, domain, company, country)
    SELECT '#{platform}', slug, any(domain), '', ''
    FROM (
      SELECT #{expr} AS slug, domain
      FROM biz_career
      WHERE url != '' AND positionCaseInsensitive(url, '#{platform_host(platform)}') > 0
    )
    WHERE slug != ''
      AND domain IN (
        SELECT domain FROM (
          SELECT domain, uniqExact(#{expr}) AS fanout
          FROM biz_career
          WHERE url != '' AND positionCaseInsensitive(url, '#{platform_host(platform)}') > 0
          GROUP BY domain
        ) WHERE fanout <= 2
      )
      -- Reserved path segments, not company slugs: workable shortlinks are
      -- /j/XXXX, greenhouse iframes are /embed/... Harvesting them would
      -- create phantom boards that 404 forever.
      AND slug NOT IN ('j', 'jobs', 'embed', 'api', 'boards', 'careers', 'v1', 'www', 'app')
      AND (('#{platform}', slug) NOT IN (SELECT platform, slug FROM hr_boards))
    GROUP BY slug
    SETTINGS max_threads = 2, max_bytes_before_external_group_by = 1000000000
    """
  end

  # ClickHouse extract() returns only the first capture group, so Workday's
  # two-part slug (host + career site) is assembled from two extracts; both
  # must match or the slug is ''.
  defp slug_expr("workday") do
    host = "extract(url, 'https?://([a-z0-9-]+\\\\.wd[0-9]+)\\\\.myworkdayjobs')"
    site = "extract(url, 'myworkdayjobs\\\\.com/(?:[a-z]{2}-[A-Z]{2}/)?([A-Za-z0-9_-]+)/job/')"
    "if(#{host} != '' AND #{site} != '', concat(#{host}, ':', #{site}), '')"
  end

  defp slug_expr(platform), do: "extract(url, '#{ch_pattern(platform)}')"

  defp ch_pattern("greenhouse"), do: "greenhouse\\\\.io/([a-z0-9_-]+)/"
  defp ch_pattern("lever"), do: "lever\\\\.co/([a-zA-Z0-9_-]+)/"
  defp ch_pattern("ashby"), do: "ashbyhq\\\\.com/([a-zA-Z0-9_-]+)/"
  defp ch_pattern("workable"), do: "workable\\\\.com/([a-z0-9-]+)/"
  defp ch_pattern("smartrecruiters"), do: "smartrecruiters\\\\.com/(?:v1/companies/)?([A-Za-z0-9]+)/"
  defp ch_pattern("recruitee"), do: "//([a-z0-9-]+)\\\\.recruitee\\\\.com"
  defp ch_pattern("personio"), do: "//([a-z0-9-]+)\\\\.jobs\\\\.personio\\\\."
  defp ch_pattern("breezy"), do: "//([a-z0-9-]+)\\\\.breezy\\\\.hr"

  defp platform_host("greenhouse"), do: "greenhouse.io"
  defp platform_host("lever"), do: "lever.co"
  defp platform_host("ashby"), do: "ashbyhq.com"
  defp platform_host("workable"), do: "workable.com"
  defp platform_host("smartrecruiters"), do: "smartrecruiters.com"
  defp platform_host("recruitee"), do: "recruitee.com"
  defp platform_host("workday"), do: "myworkdayjobs.com"
  defp platform_host("personio"), do: "jobs.personio."
  defp platform_host("breezy"), do: "breezy.hr"

  @doc """
  Link domainless boards (Common Crawl discoveries) to domains via the
  verification registry name keys. Only globally-unique keys may link — a
  name key matching two registry domains is ambiguity, and a wrong link
  would write one company's jobs under another's domain. Boards that stay
  domainless still sync (job_count lives on the board row); their
  `biz_career` writes begin the moment a later pass resolves them.
  """
  def resolve_domains_global do
    case Clickhouse.query_raw(
           """
           INSERT INTO hr_boards (platform, slug, domain, company, country, first_seen, last_synced, job_count)
           SELECT b.platform, b.slug, k.domain, b.company, b.country, b.first_seen, b.last_synced, b.job_count
           FROM (SELECT * FROM hr_boards FINAL
                 WHERE domain = '' AND platform NOT IN ('wttj', 'wttj_cursor', 'cc_discovery')) AS b
           INNER JOIN (
             SELECT name_key, any(domain) AS domain
             FROM verification_domain_keys
             GROUP BY name_key
             HAVING uniqExact(domain) = 1
           ) AS k ON replaceAll(replaceAll(
                       if(b.platform = 'workday', extract(b.slug, '^([a-z0-9-]+)\\\\.wd'), b.slug),
                       '-', ''), '_', '') = k.name_key
           SETTINGS max_threads = 2, max_bytes_before_external_group_by = 1500000000
           """,
           300_000
         ) do
      {:ok, _} ->
        case Clickhouse.query_raw(
               "SELECT countIf(domain != ''), count() FROM hr_boards FINAL WHERE platform NOT IN ('wttj', 'wttj_cursor', 'cc_discovery')"
             ) do
          {:ok, [[linked, total]]} ->
            Logger.info("[BOARDS] name-key pass: #{linked}/#{total} boards domain-linked")
            :ok

          _ ->
            :ok
        end

      err ->
        err
    end
  end

  # ── Sync: re-read known boards from the platforms' public JSON ────────────

  def sync_stale(limit \\ @max_syncs_per_run) do
    case stale_boards(limit) do
      {:ok, rows} ->
        Logger.info("[BOARDS] syncing #{length(rows)} stale boards")

        {ok, gone, err} =
          Enum.reduce(rows, {0, 0, 0}, fn [platform, slug, domain], {ok, gone, err} ->
            Process.sleep(@gap_ms)

            case sync_board(platform, slug, domain) do
              {:ok, _n} -> {ok + 1, gone, err}
              :gone -> {ok, gone + 1, err}
              :error -> {ok, gone, err + 1}
            end
          end)

        Logger.info("[BOARDS] sync done: #{ok} ok, #{gone} gone, #{err} errors")
        :ok

      err ->
        err
    end
  end

  defp stale_boards(limit) do
    Clickhouse.query_raw("""
    SELECT platform, slug, domain FROM hr_boards FINAL
    WHERE last_synced < now() - INTERVAL #{@resync_after_days} DAY
      AND platform IN ('greenhouse', 'lever', 'ashby', 'workable', 'recruitee',
                       'smartrecruiters', 'workday', 'personio', 'breezy')
    ORDER BY last_synced ASC
    LIMIT #{limit}
    """)
  end

  @doc """
  Fetch one board's public JSON and persist its jobs. `:gone` marks boards
  whose slug no longer exists (company left the platform) so we stop asking.
  """
  def sync_board(platform, slug, domain) do
    case fetch_board(platform, slug) do
      {:ok, jobs} ->
        persist_jobs(platform, slug, domain, jobs)
        {:ok, length(jobs)}

      :gone ->
        touch(platform, slug, -2)
        :gone

      :error ->
        :error
    end
  end

  defp fetch_board("greenhouse", slug),
    do: get_jobs("https://boards-api.greenhouse.io/v1/boards/#{slug}/jobs", &parse_greenhouse/1)

  defp fetch_board("lever", slug),
    do: get_jobs("https://api.lever.co/v0/postings/#{slug}?mode=json", &parse_lever/1)

  defp fetch_board("ashby", slug),
    do:
      get_jobs(
        "https://api.ashbyhq.com/posting-api/job-board/#{slug}",
        &parse_ashby/1
      )

  defp fetch_board("workable", slug),
    do: get_jobs("https://apply.workable.com/api/v1/widget/accounts/#{slug}?details=false", &parse_workable/1)

  defp fetch_board("recruitee", slug),
    do: get_jobs("https://#{slug}.recruitee.com/api/offers/", &parse_recruitee/1)

  # SmartRecruiters pages at 100 postings per call. Follow offsets so large
  # employers are not silently truncated; 10 pages (1,000 postings) is far
  # above any board we have seen.
  defp fetch_board("smartrecruiters", slug), do: fetch_smartrecruiters(slug, 0, [], 10)

  defp fetch_board("breezy", slug),
    do: get_jobs("https://#{slug}.breezy.hr/json", &parse_breezy/1)

  # Personio boards live on .de or .com depending on the account region; our
  # stored URLs are overwhelmingly .de, so try that first.
  defp fetch_board("personio", slug) do
    fetch = fn tld ->
      base = "https://#{slug}.jobs.personio.#{tld}"
      get_jobs("#{base}/xml", &parse_personio(&1, base))
    end

    case fetch.("de") do
      :gone -> fetch.("com")
      other -> other
    end
  end

  # Workday slug is "tenant.wdN:Site" (see slug_expr/1); the career-site
  # JSON is an unauthenticated POST paged at 20.
  defp fetch_board("workday", slug) do
    case String.split(slug, ":") do
      [host, site] -> fetch_workday(host, site, 0, [], 25, nil)
      _ -> :error
    end
  end

  defp fetch_board(_other, _slug), do: :error

  defp fetch_workday(_host, _site, _offset, acc, 0, _total), do: {:ok, acc}

  # `total` is only populated on the first page (offset 0 → total: 82,
  # offset 40 → total: 0 — measured on stord); carry the first page's value
  # through the recursion or paging stops at 40.
  defp fetch_workday(host, site, offset, acc, pages_left, total) do
    tenant = host |> String.split(".") |> hd()
    url = "https://#{host}.myworkdayjobs.com/wday/cxs/#{tenant}/#{site}/jobs"

    resp =
      Req.post(url,
        json: %{limit: 20, offset: offset, searchText: ""},
        receive_timeout: 20_000,
        retry: false,
        finch: LS.Finch.Bulk,
        pool_timeout: 10_000,
        headers: [{"user-agent", "ListSignalBot/1.0 (+https://listsignal.com)"}]
      )

    case resp do
      {:ok, %{status: 200, body: %{"jobPostings" => posts} = body}} when is_list(posts) ->
        total = total || body["total"] || 0

        jobs =
          for p <- posts,
              do: %{
                title: p["title"],
                location: p["locationsText"],
                url: "https://#{host}.myworkdayjobs.com/#{site}#{p["externalPath"]}"
              }

        acc = acc ++ jobs

        if length(acc) < total and posts != [] do
          Process.sleep(@gap_ms)
          fetch_workday(host, site, offset + 20, acc, pages_left - 1, total)
        else
          {:ok, acc}
        end

      {:ok, %{status: s}} when s in [404, 410] and acc == [] ->
        :gone

      _ when acc == [] ->
        :error

      # A later page failing must not throw away pages already fetched.
      _ ->
        {:ok, acc}
    end
  rescue
    _ -> if acc == [], do: :error, else: {:ok, acc}
  end

  defp fetch_smartrecruiters(_slug, _offset, acc, 0), do: {:ok, acc}

  defp fetch_smartrecruiters(slug, offset, acc, pages_left) do
    url = "https://api.smartrecruiters.com/v1/companies/#{slug}/postings?limit=100&offset=#{offset}"

    case get_jobs(url, &parse_smartrecruiters/1) do
      {:ok, jobs} when length(jobs) == 100 ->
        Process.sleep(@gap_ms)
        fetch_smartrecruiters(slug, offset + 100, acc ++ jobs, pages_left - 1)

      {:ok, jobs} ->
        {:ok, acc ++ jobs}

      :gone when acc == [] ->
        :gone

      other when acc == [] ->
        other

      # A later page failing must not throw away pages already fetched.
      _ ->
        {:ok, acc}
    end
  end

  defp get_jobs(url, parser) do
    case Req.get(url,
           receive_timeout: 20_000,
           retry: false,
           finch: LS.Finch.Bulk,
           pool_timeout: 10_000,
           headers: [{"user-agent", "ListSignalBot/1.0 (+https://listsignal.com)"}]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, parser.(body)}
      {:ok, %{status: s}} when s in [404, 410] -> :gone
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp parse_greenhouse(%{"jobs" => jobs}) when is_list(jobs) do
    for j <- jobs,
        do: %{title: j["title"], location: get_in(j, ["location", "name"]), url: j["absolute_url"]}
  end

  defp parse_greenhouse(_), do: []

  defp parse_lever(jobs) when is_list(jobs) do
    for j <- jobs,
        do: %{title: j["text"], location: get_in(j, ["categories", "location"]), url: j["hostedUrl"]}
  end

  defp parse_lever(_), do: []

  defp parse_ashby(%{"jobs" => jobs}) when is_list(jobs) do
    for j <- jobs, do: %{title: j["title"], location: j["location"], url: j["jobUrl"]}
  end

  defp parse_ashby(_), do: []

  defp parse_workable(%{"jobs" => jobs}) when is_list(jobs) do
    for j <- jobs, do: %{title: j["title"], location: j["city"], url: j["url"]}
  end

  defp parse_workable(_), do: []

  defp parse_recruitee(%{"offers" => offers}) when is_list(offers) do
    for o <- offers, do: %{title: o["title"], location: o["location"], url: o["careers_url"]}
  end

  defp parse_recruitee(_), do: []

  defp parse_smartrecruiters(%{"content" => posts}) when is_list(posts) do
    for p <- posts,
        do: %{
          title: p["name"],
          location: get_in(p, ["location", "city"]),
          url: "https://jobs.smartrecruiters.com/#{get_in(p, ["company", "identifier"])}/#{p["id"]}"
        }
  end

  defp parse_smartrecruiters(_), do: []

  defp parse_breezy(positions) when is_list(positions) do
    for p <- positions,
        do: %{title: p["name"], location: get_in(p, ["location", "name"]), url: p["url"]}
  end

  defp parse_breezy(_), do: []

  # Personio serves XML, not JSON; the shape is flat enough that a scan over
  # <position> blocks beats pulling in an XML library. Values may be wrapped
  # in CDATA. Exposed for the parser test.
  @doc false
  def parse_personio(xml, base) when is_binary(xml) do
    for [block] <- Regex.scan(~r{<position>(.*?)</position>}s, xml, capture: :all_but_first),
        (id = personio_field(block, "id")) != "" do
      %{
        title: personio_field(block, "name"),
        location: personio_field(block, "office"),
        url: "#{base}/job/#{id}"
      }
    end
  end

  def parse_personio(_, _base), do: []

  defp personio_field(block, tag) do
    case Regex.run(~r{<#{tag}>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</#{tag}>}s, block,
           capture: :all_but_first
         ) do
      [v] -> String.trim(v)
      _ -> ""
    end
  end

  # ── Persist ──────────────────────────────────────────────────────────────

  defp persist_jobs(platform, slug, domain, jobs) do
    if domain != "" do
      rows =
        Enum.map_join(jobs, "\n", fn j ->
          # job_id is UInt64 and the table dedupes on (domain, job_id): a
          # stable hash of the posting URL keeps weekly resyncs idempotent.
          [domain, stable_id(j.url || j.title), tsv(j.title), tsv(j.location), tsv(j.url), "", now_s()]
          |> Enum.join("\t")
        end)

      if rows != "" do
        Clickhouse.query_raw(
          "INSERT INTO biz_career (domain, job_id, title, location, url, posted_at, seen_at) FORMAT TabSeparated\n" <>
            rows
        )
      end

      # The log row is what the compactor folds into `businesses` — this is
      # the moment platform data becomes product data: the count plus the
      # functional snapshot ("Engineering:12|Sales:4 (18 open)").
      overview =
        jobs |> Enum.map(& &1.title) |> LS.JobCategories.summarize() |> Clickhouse.escape_public()

      Clickhouse.query_raw("""
      INSERT INTO biz_enrichment_log (domain, enriched_at, render_engine, job_count, ats_platform, positions_overview)
      VALUES ('#{Clickhouse.escape_public(domain)}', now(), 'board_sync', #{length(jobs)}, '#{platform}', '#{overview}')
      """)
    end

    touch(platform, slug, length(jobs))
  end

  defp touch(platform, slug, count) do
    Clickhouse.query_raw("""
    INSERT INTO hr_boards (platform, slug, domain, company, country, first_seen, last_synced, job_count)
    SELECT platform, slug, domain, company, country, first_seen, now(), #{count}
    FROM hr_boards FINAL WHERE platform = '#{platform}' AND slug = '#{Clickhouse.escape_public(slug)}'
    """)
  end

  defp stable_id(nil), do: "0"

  defp stable_id(text) do
    <<n::unsigned-64, _::binary>> = :crypto.hash(:sha256, to_string(text))
    Integer.to_string(n)
  end

  defp tsv(nil), do: ""

  defp tsv(s) when is_binary(s),
    do:
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\t", " ")
      |> String.replace("\n", " ")
      |> String.slice(0, 500)

  defp tsv(other), do: tsv(to_string(other))

  # Truncated to whole seconds: ClickHouse's DateTime TSV parser rejects
  # fractional seconds, and one bad value kills the entire insert batch.
  defp now_s,
    do: DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
end
