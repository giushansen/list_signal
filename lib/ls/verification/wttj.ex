defmodule LS.Verification.WTTJ do
  @moduledoc """
  Welcome to the Jungle: the French hiring directory, as a discovery source.

  Every company on WTTJ is a paying HR customer — a real, registered French
  business by construction — and its presence alone is a hiring signal. That
  makes the directory three products in one crawl: new French domains for
  pipeline 1, hiring facts for `businesses`, and a strong is-real signal for
  pipeline 3.

  The site is a JS SPA behind CloudFront that 403s bot user agents and serves
  empty shells to plain HTTP, so pages go through a camoufox sidecar with
  `settle_ms` (hydration wait). The directory is result-capped (~22 pages per
  query), so the sweep walks the unfiltered listing plus one query per letter
  to open fresh result windows. Renders are the scarcest resource in the
  fleet: the pager takes a strict per-run page budget and a full sweep
  spreads over ~2 weeks. Politeness is the point, not a limit to engineer
  around.

  Company → website domain resolves via `verification_domain_keys` (8.7M
  name keys) rather than rendering each company page; slugs that do not match
  stay domainless until a later pass renders their profile.
  """

  require Logger
  alias LS.Clickhouse

  # Pacing (revised 2026-08-27). The old 40 pages/day at 4 s was ~500× more
  # conservative than the safe envelope and left a ~43-day backlog. WTTJ sees
  # the AGGREGATE rate regardless of how many source IPs we use, so the rate
  # is chosen first: one page every ~2.5 s (gentler than the 1/2 s that
  # Hunter publishes as its own limit), then that single stream is spread
  # across the sidecar pool so no individual IP is hammered. A full directory
  # sweep (~600 pages) then clears in well under an hour.
  @pages_per_run 250
  @gap_ms 2_500
  @settle_ms 6_000

  # The unfiltered directory is result-capped at ~22 pages (~650 companies);
  # measured 2026-08-26: page 25+ renders only the wttj self-link. Letter
  # queries each open their own result window with companies the unfiltered
  # list never shows, so the sweep walks "" then a..z. One full sweep is a
  # few hundred renders — about two weeks at the per-run budget, by design.
  @queries [""] ++ Enum.map(?a..?z, &<<&1>>)

  # The render pool: WireGuard host:port of every node whose camoufox sidecar
  # is reachable from the master. Renders rotate across it so WTTJ sees a
  # single polite stream arriving from many source IPs, and no one IP — least
  # of all h1's irreplaceable residential IP — carries the whole load.
  # `LS_WTTJ_SIDECARS` (comma-separated) overrides; the legacy single
  # `LS_WTTJ_SIDECAR` still works as a one-node pool.
  @default_pool ~w(10.0.0.9:8900 10.0.0.8:8900 10.0.0.10:8900 10.0.0.14:8900 10.0.0.7:8900)

  @doc "The sidecar render pool (list of host:port)."
  def sidecar_pool do
    cond do
      (v = System.get_env("LS_WTTJ_SIDECARS")) not in [nil, ""] ->
        v |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

      (v = System.get_env("LS_WTTJ_SIDECAR")) not in [nil, ""] ->
        [v]

      true ->
        @default_pool
    end
  end

  @doc "Legacy single-sidecar accessor (first node in the pool)."
  def sidecar, do: hd(sidecar_pool())

  # Deterministic per-call rotation: no shared state, and successive pages
  # land on different IPs.
  defp pick_sidecar(n), do: Enum.at(sidecar_pool(), rem(n, length(sidecar_pool())))

  def ingest(pages \\ @pages_per_run) do
    {qi, page} = cursor()
    Logger.info("[WTTJ] ingest from query #{qi} page #{page}, budget #{pages}")

    Enum.reduce_while(1..pages, {qi, page, 0}, fn i, {qi, page, acc} ->
      Process.sleep(@gap_ms)

      case fetch_directory_page(Enum.at(@queries, qi), page, pick_sidecar(i)) do
        {:ok, []} ->
          # End of this query's result window: move to the next query, or
          # wrap the whole sweep back to the start.
          next_qi = if qi + 1 < length(@queries), do: qi + 1, else: 0
          Logger.info("[WTTJ] query #{qi} exhausted at page #{page}, moving to query #{next_qi}")
          set_cursor(next_qi, 1)
          {:cont, {next_qi, 1, acc}}

        {:ok, slugs} ->
          store_slugs(slugs)
          set_cursor(qi, page + 1)
          {:cont, {qi, page + 1, acc + length(slugs)}}

        :error ->
          Logger.warning("[WTTJ] query #{qi} page #{page} failed, stopping run")
          {:halt, {qi, page, acc}}
      end
    end)
    |> then(fn {_, _, n} ->
      resolved = resolve_domains()
      Logger.info("[WTTJ] run done: #{n} slugs seen, #{resolved} domains resolved")
      :ok
    end)
  end

  @doc false
  def fetch_directory_page(query, page, sidecar \\ nil) do
    qs = if query == "", do: "page=#{page}", else: "query=#{query}&page=#{page}"

    case render("/fr/companies?#{qs}", sidecar || sidecar()) do
      {:ok, html} -> {:ok, extract_slugs(html)}
      :error -> :error
    end
  end

  defp render(path, sidecar) do
    body =
      Jason.encode!(%{
        domain: "www.welcometothejungle.com",
        path: path,
        settle_ms: @settle_ms
      })

    case Req.post("http://#{sidecar}/render",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 120_000,
           retry: false,
           finch: LS.Finch.Bulk,
           pool_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"html" => html}}} when is_binary(html) ->
        {:ok, html}

      other ->
        Logger.debug("[WTTJ] render #{path} failed: #{inspect(other) |> String.slice(0, 120)}")
        :error
    end
  rescue
    _ -> :error
  end

  @doc "Company slugs from a rendered directory page. Pure, tested."
  def extract_slugs(html) do
    ~r{href="/fr/companies/([a-z0-9-]+)"}
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&(&1 in ["wttj", "welcome-to-the-jungle"]))
  end

  # Hosts that appear as external links on every profile but are never the
  # company's website.
  @not_a_website ~w(
    welcometothejungle wttj axept.io googleapis maps.google linkedin.com
    youtube.com twitter.com x.com facebook.com instagram.com tiktok.com
    glassdoor apple.com play.google medium.com
  )

  @doc """
  The company's website from a rendered profile page, as a bare domain.
  Measured 2026-08-26: the site link is the first external href that is not
  a social/utility host (e.g. `https://www.abridge.com` on /fr/companies/abridge).
  Pure; returns nil when no candidate survives.
  """
  def extract_website(html) do
    html
    |> hrefs()
    |> Enum.reject(fn url -> Enum.any?(@not_a_website, &String.contains?(url, &1)) end)
    |> Enum.map(&URI.parse(&1).host)
    |> Enum.find(&(is_binary(&1) and String.contains?(&1, ".")))
    |> case do
      nil -> nil
      host -> String.replace_prefix(host, "www.", "")
    end
  end

  @doc """
  Whether a profile render actually hydrated. A loading shell links only to
  welcometothejungle CDNs (measured: 270 KB of asset hrefs, nothing else);
  a hydrated profile always carries at least one non-WTTJ href (consent CDN,
  socials, website). Distinguishing the two matters: no-website on a
  hydrated page is a durable fact, on a shell it is a render failure that
  must be retried.
  """
  def hydrated?(html) do
    html
    |> hrefs()
    |> Enum.any?(&(not String.contains?(&1, "welcometothejungle")))
  end

  defp hrefs(html) do
    ~r{href="(https?://[^"]+)"}
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  @doc """
  Resolve unresolved slugs by rendering their profile pages (the profile
  shows the company website — registry name keys only match ~5% because
  legal names differ from brand names). One render per slug, so the budget
  is deliberately small; failures are marked (job_count = -3) and not
  retried, keeping the sweep from burning renders on dead profiles.
  """
  def resolve_via_profiles(limit \\ 120) do
    case Clickhouse.query_raw("""
         SELECT slug FROM hr_boards FINAL
         WHERE platform = 'wttj' AND domain = '' AND job_count != -3
         ORDER BY first_seen ASC LIMIT #{limit}
         """) do
      {:ok, rows} ->
        n =
          rows
          |> Enum.with_index()
          |> Enum.count(fn {[slug], i} ->
            Process.sleep(@gap_ms)
            resolve_profile(slug, pick_sidecar(i))
          end)

        Logger.info("[WTTJ] profile pass: #{n}/#{length(rows)} slugs resolved to domains")
        :ok

      err ->
        err
    end
  end

  defp resolve_profile(slug, sidecar) do
    case render("/fr/companies/#{slug}", sidecar) do
      {:ok, html} ->
        case {hydrated?(html), extract_website(html)} do
          # Loading shell: render failure, leave the slug for the next pass.
          {false, _} ->
            false

          {true, nil} ->
            mark_unresolvable(slug)
            false

          {true, domain} ->
            Clickhouse.query_raw("""
            INSERT INTO hr_boards (platform, slug, domain, company, country, first_seen, last_synced, job_count)
            SELECT platform, slug, '#{Clickhouse.escape_public(domain)}', company, country, first_seen, now(), job_count
            FROM hr_boards FINAL WHERE platform = 'wttj' AND slug = '#{Clickhouse.escape_public(slug)}'
            """)

            true
        end

      :error ->
        false
    end
  end

  defp mark_unresolvable(slug) do
    Clickhouse.query_raw("""
    INSERT INTO hr_boards (platform, slug, domain, company, country, first_seen, last_synced, job_count)
    SELECT platform, slug, domain, company, country, first_seen, now(), -3
    FROM hr_boards FINAL WHERE platform = 'wttj' AND slug = '#{Clickhouse.escape_public(slug)}'
    """)
  end

  defp store_slugs(slugs) do
    values =
      Enum.map_join(slugs, ",", fn slug ->
        "('wttj', '#{Clickhouse.escape_public(slug)}', '', '', 'FR')"
      end)

    Clickhouse.query_raw("""
    INSERT INTO hr_boards (platform, slug, domain, company, country)
    SELECT platform, slug, domain, company, country FROM (
      SELECT arrayJoin([#{values}]) AS t,
             t.1 AS platform, t.2 AS slug, t.3 AS domain, t.4 AS company, t.5 AS country
    )
    WHERE (platform, slug) NOT IN (SELECT platform, slug FROM hr_boards)
    """)
  end

  # Match WTTJ slugs against the registry-derived name keys. A slug like
  # "alan" or "back-market" dehyphenates into exactly the normalised form
  # verification_domain_keys stores, so this resolves a large share without a
  # single extra render.
  defp resolve_domains do
    case Clickhouse.query_raw("""
         INSERT INTO hr_boards (platform, slug, domain, company, country, first_seen, last_synced, job_count)
         SELECT b.platform, b.slug, k.domain, b.company, b.country, b.first_seen, b.last_synced, b.job_count
         FROM hr_boards AS b FINAL
         INNER JOIN (
           SELECT name_key, any(domain) AS domain
           FROM verification_domain_keys
           WHERE country = 'FR'
           GROUP BY name_key
         ) AS k ON replaceAll(b.slug, '-', '') = k.name_key
         WHERE b.platform = 'wttj' AND b.domain = ''
         SETTINGS max_threads = 2, max_bytes_before_external_group_by = 1000000000, join_use_nulls = 0
         """) do
      {:ok, _} ->
        case Clickhouse.query_raw(
               "SELECT countIf(domain != '') FROM hr_boards FINAL WHERE platform = 'wttj'"
             ) do
          {:ok, [[n]]} -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  # The cursor rides in hr_boards as a synthetic row ("qi:page" in `company`):
  # no new table for two ints. Old single-int cursors read as {0, page}.
  defp cursor do
    case Clickhouse.query_raw(
           "SELECT argMax(company, last_synced) FROM hr_boards FINAL WHERE platform = 'wttj_cursor'"
         ) do
      {:ok, [[c]]} when is_binary(c) -> parse_cursor(c)
      _ -> {0, 1}
    end
  end

  @doc "Parse a stored sweep cursor. Pure; hostile input degrades to the sweep start."
  def parse_cursor(c) do
    case String.split(to_string(c), ":") do
      [qi, page] -> {min(to_int(qi), length(@queries) - 1), max(to_int(page), 1)}
      [page] -> {0, max(to_int(page), 1)}
      _ -> {0, 1}
    end
  end

  defp set_cursor(qi, page) do
    Clickhouse.query_raw(
      "INSERT INTO hr_boards (platform, slug, domain, company, country, last_synced) VALUES ('wttj_cursor', 'cursor', '', '#{qi}:#{page}', '', now())"
    )
  end

  defp to_int(s) do
    case Integer.parse(to_string(s)) do
      {n, _} when n >= 0 -> n
      _ -> 0
    end
  end
end
