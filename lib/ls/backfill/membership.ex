defmodule LS.Backfill.Membership do
  @moduledoc """
  Compiles into `businesses` the sites we read but never gave a row
  (2026-11-12). Run by hand on the master, one page at a time:

      LS.Backfill.Membership.start()   # resumes from the saved cursor
      LS.Backfill.Membership.status()
      LS.Backfill.Membership.stop()

  From 2026-09-07 to 10-03 only sites the classifier labelled became
  businesses (see the HAVING comment in `LS.Clickhouse.Compact`). Since
  10-03 any readable, non-junk site with a title is one again, but a site
  read in that window only gets its row when something touches it again.
  Measured on prod 2026-11-12 over the `be` range (1.08% of businesses):
  127,616 English or French non-junk sites with a title had no row against
  305,614 that did, 39,881 of them with an email, 84 behind Shopify. That
  is about 11.8M sites and 3.7M with an email fleet-wide, invisible to
  every search, list and export.

  This compiles the ones with an email, the sellable part, through the
  ordinary fold (`LS.Clickhouse.Compact.compact_domains/1`, the full
  history of each domain, at most 2,000 a call), so the row is what the
  next incremental pass would have written. No fetch: the data is that of
  the last visit, dated by `http_last_checked_at`, and the scheduler
  refreshes the tier A ones on its own clock behind first visits. The walk
  is a keyset cursor over sorted domain ranges (`LS.Backfill.Ranges`), one
  page in flight, a pause between pages, the cursor saved after each page.
  """

  require Logger

  alias LS.Backfill.Ranges
  alias LS.Schema.Tables

  @page 2_000
  @pause_ms 2_000
  @cursor_file "membership_backfill_cursor.bin"
  @pt {__MODULE__, :progress}

  @doc "Start (or resume) the walk in the background. `{:error, :running}` if it already runs."
  def start do
    case status() do
      %{running: true} ->
        {:error, :running}

      _ ->
        :persistent_term.put({__MODULE__, :stop}, false)
        cursor = Ranges.load(cursor_path())
        put(%{running: true, cursor: cursor, pages: 0, compiled: 0, failed: 0, started_at: DateTime.utc_now()})
        Task.start(fn -> walk(cursor) end)
        {:ok, cursor}
    end
  end

  @doc "Stop after the page in flight."
  def stop, do: :persistent_term.put({__MODULE__, :stop}, true)

  @doc "Progress of this boot's walk."
  def status, do: :persistent_term.get(@pt, %{running: false})

  @doc """
  Pure: one page of sites at `cursor` with an observed fetch, last read in
  English or French, not junk, with a title and an email on some observed
  visit, never flagged malware or phishing, and no `businesses` row.
  """
  @spec page_sql({non_neg_integer(), String.t() | nil}) :: String.t()
  def page_sql({index, after_domain}) do
    where = Ranges.where_sql(Ranges.at(index), after_domain)
    obs = LS.Clickhouse.Compact.observed_sql()
    lang = String.replace(LS.Crawl.Markets.refresh_language_sql(), "http_language", "lang")

    """
    SELECT domain FROM (
      SELECT domain,
             maxIf(http_emails != '', #{obs}) AS em,
             argMaxIf(http_language, enriched_at, #{obs}) AS lang,
             argMaxIf(is_junk, enriched_at, #{obs}) AS junk,
             argMaxIf(http_title, enriched_at, #{obs}) AS title
      FROM #{Tables.enrich_log()}
      WHERE #{where}
      GROUP BY domain
      HAVING max(#{obs}) = 1 AND max(is_malware != '' OR is_phishing != '') = 0
    )
    WHERE em AND #{lang} AND junk = '' AND title != ''
      AND domain NOT IN (SELECT domain FROM #{Tables.businesses()} WHERE #{where})
    ORDER BY domain
    LIMIT #{@page}
    SETTINGS max_threads = 2, max_execution_time = 120, max_memory_usage = 3000000000
    """
  end

  defp walk(:done) do
    Logger.info("[MEMBERSHIP] backfill DONE: #{inspect(status())}")
    put(%{status() | running: false, cursor: :done})
  end

  defp walk(cursor) do
    if :persistent_term.get({__MODULE__, :stop}, false) do
      Logger.info("[MEMBERSHIP] stopped at #{inspect(cursor)}: #{inspect(status())}")
      put(%{status() | running: false})
    else
      walk(cursor, step(cursor))
    end
  end

  defp walk(cursor, {:ok, next, compiled}) do
    if next == :done, do: File.rm(cursor_path()), else: Ranges.save(cursor_path(), next)
    s = status()
    put(%{s | cursor: next, pages: s.pages + 1, compiled: s.compiled + compiled})

    if rem(s.pages + 1, 50) == 0,
      do: Logger.info("[MEMBERSHIP] range #{elem(cursor, 0)} of #{Ranges.count()}: #{s.compiled + compiled} compiled in #{s.pages + 1} pages")

    Process.sleep(@pause_ms)
    walk(next)
  end

  # A failed page is retried after a minute, then skipped past (its range
  # is logged), so one bad range cannot stall the walk.
  defp walk(cursor, {:error, reason}) do
    s = status()
    Logger.warning("[MEMBERSHIP] page #{inspect(cursor)} failed: #{inspect(reason) |> String.slice(0, 300)}")
    put(%{s | failed: s.failed + 1})
    Process.sleep(60_000)

    case step(cursor) do
      {:ok, _, _} = ok -> walk(cursor, ok)
      {:error, _} -> walk(Ranges.advance(cursor, [], @page))
    end
  end

  defp step(cursor) do
    with {:ok, rows} when is_list(rows) <- LS.Clickhouse.query_raw(page_sql(cursor), 150_000),
         domains = Ranges.safe_domains(rows),
         {:ok, _} <- compile(domains) do
      {:ok, Ranges.advance(cursor, domains, @page), length(domains)}
    else
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, _} = err -> err
    end
  end

  defp compile([]), do: {:ok, 0}
  defp compile(domains), do: LS.Clickhouse.Compact.compact_domains(domains)

  defp put(progress), do: :persistent_term.put(@pt, progress)

  defp cursor_path, do: Path.join(LS.State.dir(), @cursor_file)
end
