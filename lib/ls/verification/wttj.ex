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
  `settle_ms` (hydration wait). Renders are the scarcest resource in the
  fleet: the pager takes a strict per-run page budget and the whole directory
  (~1.5k pages) spreads over weeks. Politeness is the point, not a limit to
  engineer around.

  Company → website domain resolves via `verification_domain_keys` (8.7M
  name keys) rather than rendering each company page; slugs that do not match
  stay domainless until a later pass renders their profile.
  """

  require Logger
  alias LS.Clickhouse

  @pages_per_run 40
  @gap_ms 4_000
  @settle_ms 6_000

  @doc "Sidecar host:port used for renders (a worker's WireGuard address)."
  def sidecar, do: System.get_env("LS_WTTJ_SIDECAR", "10.0.0.7:8900")

  def ingest(pages \\ @pages_per_run) do
    start = next_page()
    Logger.info("[WTTJ] ingest from page #{start}, budget #{pages}")

    Enum.reduce_while(start..(start + pages - 1), 0, fn page, acc ->
      Process.sleep(@gap_ms)

      case fetch_directory_page(page) do
        {:ok, []} ->
          Logger.info("[WTTJ] page #{page} empty — end of directory, wrapping to 1")
          set_next_page(1)
          {:halt, acc}

        {:ok, slugs} ->
          store_slugs(slugs)
          set_next_page(page + 1)
          {:cont, acc + length(slugs)}

        :error ->
          Logger.warning("[WTTJ] page #{page} failed, stopping run")
          {:halt, acc}
      end
    end)
    |> then(fn n ->
      resolved = resolve_domains()
      Logger.info("[WTTJ] run done: #{n} slugs seen, #{resolved} domains resolved")
      :ok
    end)
  end

  @doc false
  def fetch_directory_page(page) do
    body =
      Jason.encode!(%{
        domain: "www.welcometothejungle.com",
        path: "/fr/companies?page=#{page}",
        settle_ms: @settle_ms
      })

    case Req.post("http://#{sidecar()}/render",
           body: body,
           headers: [{"content-type", "application/json"}],
           receive_timeout: 120_000,
           retry: false,
           finch: LS.Finch.Bulk,
           pool_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: %{"html" => html}}} when is_binary(html) ->
        {:ok, extract_slugs(html)}

      other ->
        Logger.debug("[WTTJ] render failed: #{inspect(other) |> String.slice(0, 120)}")
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

  defp next_page do
    case Clickhouse.query_raw(
           "SELECT max(toInt32OrZero(company)) FROM hr_boards FINAL WHERE platform = 'wttj_cursor'"
         ) do
      {:ok, [[n]]} when is_integer(n) and n > 0 -> n
      {:ok, [[n]]} when is_binary(n) -> max(String.to_integer(n), 1)
      _ -> 1
    end
  end

  # The cursor rides in hr_boards as a synthetic row: no new table for one int.
  defp set_next_page(page) do
    Clickhouse.query_raw(
      "INSERT INTO hr_boards (platform, slug, domain, company, country, last_synced) VALUES ('wttj_cursor', 'cursor', '', '#{page}', '', now())"
    )
  end
end
