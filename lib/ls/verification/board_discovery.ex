defmodule LS.Verification.BoardDiscovery do
  @moduledoc """
  Board discovery from the Common Crawl URL index.

  The careers-page harvest only finds boards our crawlers have stumbled on
  (~750). The platforms host tens of thousands more, but their sitemaps are
  SPA fallbacks and enumerating them directly would be scraping. Common
  Crawl's CDX index is a public archive of every URL its web-wide crawl has
  seen — querying `jobs.lever.co/*` yields every known board with zero
  requests to the ATS itself (measured 2026-08-26: ~900 distinct slugs per
  single index page).

  Discovered boards land in `hr_boards` with `domain=''`; the weekly sync
  still reads them (job_count + gone-marking live on the board row), and
  `biz_career`/`businesses` writes begin the moment a domain is resolved —
  by the careers harvest, the global name-key pass, or a future linker.
  The slug is durable; the domain arrives when it arrives.

  Politeness: this hits only index.commoncrawl.org (a service built for
  bulk queries), one request at a time with a fixed gap and bounded pages
  per host. Runs monthly — the index updates on that cadence.
  """

  require Logger
  alias LS.Clickhouse
  alias LS.Verification.HRBoards

  @cdx_gap_ms 1_500
  @max_pages_per_query 40
  @insert_chunk 500
  @rerun_after_days 25

  # CDX queries per platform. :prefix enumerates a path space, :domain a
  # subdomain space. Slugs are extracted with the same patterns the
  # careers harvest uses, so the two discovery paths can never disagree.
  @queries [
    {"greenhouse", "boards.greenhouse.io/*", :prefix},
    {"greenhouse", "job-boards.greenhouse.io/*", :prefix},
    {"lever", "jobs.lever.co/*", :prefix},
    {"lever", "jobs.eu.lever.co/*", :prefix},
    {"ashby", "jobs.ashbyhq.com/*", :prefix},
    {"smartrecruiters", "jobs.smartrecruiters.com/*", :prefix},
    {"workable", "apply.workable.com/*", :prefix},
    {"recruitee", "recruitee.com", :domain},
    {"breezy", "breezy.hr", :domain},
    {"personio", "jobs.personio.de", :domain},
    {"personio", "jobs.personio.com", :domain},
    {"workday", "myworkdayjobs.com", :domain}
  ]

  @reserved ~w(j jobs embed api boards careers v1 www app wd sitemap assets cdn)

  @doc "Query specs exposed for the contract test."
  def queries, do: @queries

  @doc """
  Enumerate platforms from the newest Common Crawl index and store new
  boards. Idempotent; safe to re-run. `only` narrows to specific platforms
  (ops/testing). Returns `{:ok, inserted_count}`.
  """
  def run(only \\ nil) do
    case newest_index() do
      {:ok, cdx} ->
        Logger.info("[BOARDS] CC discovery from #{cdx}")

        inserted =
          @queries
          |> Enum.filter(fn {platform, _, _} -> only == nil or platform in only end)
          |> Enum.reduce(0, fn {platform, q, mode}, acc ->
            slugs = enumerate(cdx, platform, q, mode)
            n = store_new(platform, slugs)
            Logger.info("[BOARDS] CC #{platform} #{q}: #{MapSet.size(slugs)} slugs seen, #{n} new")
            acc + n
          end)

        if only == nil, do: mark_ran()
        Logger.info("[BOARDS] CC discovery done: #{inserted} new boards")
        {:ok, inserted}

      err ->
        Logger.warning("[BOARDS] CC discovery skipped: #{inspect(err)}")
        err
    end
  end

  @doc "Run only if the last completed run is older than #{@rerun_after_days} days."
  def run_if_due do
    case Clickhouse.query_raw(
           "SELECT max(last_synced) FROM hr_boards FINAL WHERE platform = 'cc_discovery'"
         ) do
      {:ok, [[ts]]} when is_binary(ts) ->
        case NaiveDateTime.from_iso8601(String.replace(ts, " ", "T")) do
          {:ok, last} ->
            if NaiveDateTime.diff(NaiveDateTime.utc_now(), last, :day) >= @rerun_after_days,
              do: run(),
              else: :not_due

          _ ->
            run()
        end

      _ ->
        run()
    end
  end

  defp mark_ran do
    Clickhouse.query_raw(
      "INSERT INTO hr_boards (platform, slug, domain, company, country, last_synced) VALUES ('cc_discovery', 'cursor', '', '', '', now())"
    )
  end

  # ── CDX ───────────────────────────────────────────────────────────────────

  defp newest_index do
    case cdx_get("https://index.commoncrawl.org/collinfo.json") do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, [%{"cdx-api" => api} | _]} -> {:ok, api}
          _ -> {:error, :collinfo_shape}
        end

      err ->
        err
    end
  end

  defp enumerate(cdx, platform, q, mode) do
    mt = if mode == :domain, do: "&matchType=domain", else: ""
    base = "#{cdx}?url=#{URI.encode_www_form(q)}#{mt}&output=json&fields=url"

    pages =
      case cdx_get("#{base}&showNumPages=true") do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, %{"pages" => n}} -> n
            _ -> 0
          end

        _ ->
          0
      end

    if pages > @max_pages_per_query,
      do: Logger.warning("[BOARDS] CC #{q}: #{pages} pages, capping at #{@max_pages_per_query} — rerun next month picks up the rest")

    0..(min(pages, @max_pages_per_query) - 1)//1
    |> Enum.reduce(MapSet.new(), fn page, acc ->
      case cdx_get("#{base}&page=#{page}") do
        {:ok, body} -> extract_page_slugs(body, platform, acc)
        _ -> acc
      end
    end)
  end

  @doc "Slugs from one CDX result page (JSON lines with a url field). Pure."
  def extract_page_slugs(body, platform, acc \\ MapSet.new()) do
    {_, re} = List.keyfind(HRBoards.patterns(), platform, 0)

    body
    |> String.splitter("\n")
    |> Enum.reduce(acc, fn line, acc ->
      with [_, url] <- Regex.run(~r/"url":\s*"([^"]+)"/, line),
           slug when is_binary(slug) <- slug_from_url(url, platform, re) do
        MapSet.put(acc, slug)
      else
        _ -> acc
      end
    end)
  end

  defp slug_from_url(url, "workday", re) do
    case Regex.run(re, url, capture: :all_but_first) do
      # Hostnames are case-insensitive; the site segment is not.
      [host, site] -> "#{String.downcase(host)}:#{site}"
      _ -> nil
    end
  end

  # Original case is preserved: several APIs treat slugs case-sensitively
  # (smartrecruiters, ashby), and the careers harvest stores them as-is.
  defp slug_from_url(url, _platform, re) do
    case Regex.run(re, url, capture: :all_but_first) do
      [slug | _] -> validate(slug)
      _ -> nil
    end
  end

  defp validate(slug) do
    cond do
      String.downcase(slug) in @reserved -> nil
      byte_size(slug) < 2 or byte_size(slug) > 80 -> nil
      true -> slug
    end
  end

  defp cdx_get(url, attempt \\ 1) do
    Process.sleep(@cdx_gap_ms)

    case Req.get(url,
           receive_timeout: 120_000,
           retry: false,
           decode_body: false,
           finch: LS.Finch.Bulk,
           pool_timeout: 30_000,
           headers: [{"user-agent", "ListSignalBot/1.0 (+https://listsignal.com)"}]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      # The CDX service 503s under load; back off once before giving up on
      # the page (the monthly rerun makes any gap self-healing).
      {:ok, %{status: 503}} when attempt < 3 ->
        Process.sleep(10_000)
        cdx_get(url, attempt + 1)

      other ->
        {:error, other |> inspect() |> String.slice(0, 120)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Store ─────────────────────────────────────────────────────────────────

  defp store_new(platform, slugs) do
    existing =
      case Clickhouse.query_raw("SELECT slug FROM hr_boards WHERE platform = '#{platform}'") do
        {:ok, rows} -> MapSet.new(rows, fn [s] -> s end)
        _ -> MapSet.new()
      end

    fresh = MapSet.difference(slugs, existing)

    fresh
    |> MapSet.to_list()
    |> Enum.chunk_every(@insert_chunk)
    |> Enum.reduce(0, fn chunk, acc ->
      values =
        Enum.map_join(chunk, ",", fn slug ->
          "('#{platform}', '#{Clickhouse.escape_public(slug)}')"
        end)

      case Clickhouse.query_raw("""
           INSERT INTO hr_boards (platform, slug, domain, company, country)
           SELECT platform, slug, '', '', '' FROM (
             SELECT arrayJoin([#{values}]) AS t, t.1 AS platform, t.2 AS slug
           )
           WHERE (platform, slug) NOT IN (SELECT platform, slug FROM hr_boards)
           """) do
        {:ok, _} -> acc + length(chunk)
        _ -> acc
      end
    end)
  end
end
