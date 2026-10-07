defmodule LS.Backfill.Reclassify do
  @moduledoc """
  Re-runs the business classifier over the stored homepage blocks
  (`http_pages`) and writes a classification row to `enrich_log` wherever
  the verdict differs from what `businesses` serves. Written 2026-10-07.

  Why: the golden v6 classifier (4338f15, da057a1) raises precision mostly
  by withholding labels, and the product fold kept the last non-empty
  label, so 4.68M WooCommerce-only domains stayed Ecommerce at 97% in the
  product while the new code labels 26% of that pattern. Re-crawling could
  not fix them: a withheld label looked like "wrote nothing" to the fold
  until `classification_source` "none" became a verdict the same day
  (`LS.Clickhouse.Compact.evaluated_sql/1`). The stored blocks let the
  classifier revisit 1.8M sites without a fetch, which is what they were
  kept for.

  Runs on the master, the only node that reads ClickHouse, and borrows the
  workers' ML heads over erpc for the rows the heuristic leaves undecided,
  so the master's four cores stay with ClickHouse.

      LS.Backfill.Reclassify.start()
      LS.Backfill.Reclassify.start(cutoff: "2026-10-05 22:00:00", batch: 1000, pause_ms: 250)
      LS.Backfill.Reclassify.start(since: "2026-10-05 22:00:00", cutoff: "2026-10-07 03:00:00")
      LS.Backfill.Reclassify.status()
      LS.Backfill.Reclassify.stop()

  A domain whose last fetch is after `cutoff` was already judged by the
  new code and is skipped; so is a page flagged as junk. `since` bounds
  the window from below for a second pass: the fleet fetched 732K domains
  between the classifier deploy and the fold fix, and wrote their withheld
  verdicts as an empty source the fold cannot see, so those are replayed
  too (112K of them served a stale label on 2026-10-07).

  How a verdict is written: as the liveness pass does it for dead sites, a
  full copy of the domain's newest real `enrich_log` row with the
  overrides (`worker` "master", `http_status` NULL, `http_observed` 0,
  `http_error` empty, the four classification columns, `pipeline_version`
  "backfill-<sha>"), never a classification-only row. The first run of
  this module (2026-10-07, 04:45 to 08:05 UTC) wrote hollow rows;
  `mv_domains` copies every enrich_log insert into `domains`, which is
  newest-row-wins, so 126,182 domains had a row with no DNS, HTTP or BGP at
  the top of the store page read and the data-quality checks alerted on
  three empty columns. The copy is taken from `enrich_log`, not `domains`:
  `domains` has 56 columns and the mail and page facts added since
  (DMARC, DKIM, BIMI, address, phone) fold on the same row as `dns_mx`, so
  a 56-column copy would blank them. A null status keeps the copy out of
  every HTTP fold; only the classification unit, which keys on
  "evaluated", takes it. The compactor folds it on its next pass.
  """

  require Logger

  alias LS.HTTP.BusinessClassifier

  @default_cutoff "2026-10-05 22:00:00"
  @version "backfill-" <> LS.Version.sha()
  @ml_chunk 32
  @ml_floor 0.55
  @stats_key {__MODULE__, :stats}
  @pid_key {__MODULE__, :pid}

  # ── control ───────────────────────────────────────────────────────────

  @doc "Starts the run in a background task; `{:error, :running}` if one is live."
  def start(opts \\ []) do
    if running?() do
      {:error, :running}
    else
      opts = Keyword.merge([since: nil, cutoff: @default_cutoff, batch: 1000, pause_ms: 250, cursor: ""], opts)
      {:ok, pid} = Task.start(fn -> run(opts) end)
      :persistent_term.put(@pid_key, pid)
      {:ok, pid}
    end
  end

  def stop do
    case :persistent_term.get(@pid_key, nil) do
      pid when is_pid(pid) -> Process.exit(pid, :kill); :ok
      _ -> :ok
    end
  end

  def running? do
    case :persistent_term.get(@pid_key, nil) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  def status, do: Map.put(:persistent_term.get(@stats_key, %{}), :running, running?())

  # ── the run ───────────────────────────────────────────────────────────

  defp run(opts) do
    stats = %{batches: 0, scanned: 0, evaluated: 0, same: 0, cleared: 0, relabeled: 0, added: 0,
              ml_texts: 0, written: 0, errors: 0, cursor: opts[:cursor], started_at: now_s(), finished: false}
    put_stats(stats)
    Logger.info("[BACKFILL] reclassify started since=#{opts[:since]} cutoff=#{opts[:cutoff]} batch=#{opts[:batch]} cursor=#{inspect(opts[:cursor])}")
    loop(opts, stats)
  end

  defp loop(opts, stats) do
    case fetch_pages(stats.cursor, opts[:batch]) do
      {:ok, []} ->
        Logger.info("[BACKFILL] reclassify finished: #{inspect(Map.drop(stats, [:cursor]))}")
        put_stats(%{stats | finished: true})

      {:ok, pages} ->
        {pages, next_cursor} = trim_split_domain(pages, opts[:batch])
        stats = process_batch(pages, opts, %{stats | cursor: next_cursor})
        put_stats(stats)
        if rem(stats.batches, 20) == 0, do: Logger.info("[BACKFILL] #{inspect(Map.drop(stats, [:started_at]))}")
        Process.sleep(opts[:pause_ms])
        loop(opts, stats)

      {:error, reason} ->
        Logger.warning("[BACKFILL] page read failed at #{stats.cursor}: #{inspect(reason)}; retrying in 30s")
        put_stats(%{stats | errors: stats.errors + 1})
        Process.sleep(30_000)
        loop(opts, stats)
    end
  end

  defp process_batch(pages, opts, stats) do
    domains = Enum.map(pages, & &1.domain)

    case fetch_businesses(domains) do
      {:ok, biz} ->
        items =
          for p <- pages, b = biz[p.domain], eligible?(b, opts[:since], opts[:cutoff]) do
            sig = signals(p, b)
            {b, sig, BusinessClassifier.classify(sig)}
          end

        needs_ml = for {b, sig, heur} <- items, heur.confidence < @ml_floor, t = ml_text(sig, b), byte_size(t) > 20, do: {b.domain, t}
        ml = ml_batch(needs_ml)

        decisions =
          for {b, _sig, heur} <- items do
            final =
              case ml[b.domain] do
                nil -> Map.put_new(heur, :source, nil)
                m -> LS.Pipeline.merge_classification(heur, m)
              end

            {b, final, decision(b.business_model, final.business_model)}
          end

        rows = for {b, final, d} <- decisions, d != :same, do: verdict(b.domain, final)
        write = if rows == [], do: :ok, else: insert_verdicts(rows)

        counts = Enum.frequencies_by(decisions, fn {_, _, d} -> d end)

        %{stats |
          batches: stats.batches + 1,
          scanned: stats.scanned + length(pages),
          evaluated: stats.evaluated + length(items),
          same: stats.same + Map.get(counts, :same, 0),
          cleared: stats.cleared + Map.get(counts, :cleared, 0),
          relabeled: stats.relabeled + Map.get(counts, :relabeled, 0),
          added: stats.added + Map.get(counts, :added, 0),
          ml_texts: stats.ml_texts + length(needs_ml),
          written: stats.written + (if write == :ok, do: length(rows), else: 0),
          errors: stats.errors + (if write == :ok, do: 0, else: 1)}

      {:error, reason} ->
        Logger.warning("[BACKFILL] businesses read failed: #{inspect(reason)}")
        %{stats | batches: stats.batches + 1, scanned: stats.scanned + length(pages), errors: stats.errors + 1}
    end
  end

  # ── pure pieces (tested) ──────────────────────────────────────────────

  @doc "What the verdict means against the label the product serves."
  @spec decision(String.t(), String.t()) :: :same | :cleared | :relabeled | :added
  def decision(current, new) do
    cond do
      current == new -> :same
      new == "" -> :cleared
      current == "" -> :added
      true -> :relabeled
    end
  end

  @doc "A page is revisited when its last fetch falls in [since, cutoff) and it is not junk."
  def eligible?(b, since \\ nil, cutoff),
    do: b.is_junk == "" and b.http_last_checked_at < cutoff and (is_nil(since) or b.http_last_checked_at >= since)

  @doc """
  The classifier's signal map, built from the product row and the stored
  blocks the way `LS.Pipeline` builds it from a live fetch: body text is
  the first 500 characters of visible text, header first.
  """
  def signals(page, b) do
    body =
      [page.header, page.body, page.footer]
      |> Enum.concat()
      |> Enum.join(" ")
      |> String.slice(0, 500)

    %{
      http_tech: b.http_tech, http_apps: b.http_apps, http_title: b.http_title,
      http_meta_description: b.http_meta_description, http_pages: b.http_pages,
      http_schema_type: b.http_schema_type, http_og_type: "", ctl_tld: b.ctl_tld, dns_txt: "",
      h1: b.http_h1, body_text: body, nav_links: b.http_nav_links,
      http_status: b.last_http_status || 200, is_js_site: false, rdap_nameservers: b.rdap_nameservers,
      http_address: b.http_address, http_phone: b.http_phone, domain: b.domain
    }
  end

  @doc "The text the ML head embeds, with the same hint the worker attaches."
  def ml_text(sig, b) do
    text = Enum.join([sig.http_title, sig.h1, sig.http_meta_description, sig.body_text], " ")

    LS.ML.Features.text_with_hint(text, %{
      http_tech: b.http_tech, http_apps: b.http_apps, dns_mx: b.dns_mx, dns_dmarc: b.dns_dmarc,
      dns_dkim: b.dns_dkim, dns_ms_enterprise: b.dns_ms_enterprise, dns_bimi: b.dns_bimi
    })
  end

  @doc "One verdict as the VALUES tuple the write joins on: domain and the four classification columns."
  def verdict(domain, final) do
    {domain, final.business_model, final.industry, final.confidence, LS.Pipeline.classification_source(final, true)}
  end

  @doc """
  The INSERT ... SELECT that writes a batch of verdicts: each domain's
  newest real `enrich_log` row (earlier backfill rows are never a source),
  copied with the overrides and the verdict joined in from a VALUES table.
  `cols` is the insertable column list of `enrich_log`. The newest
  timestamp per domain is found first on three narrow columns and the wide
  row is read only for that one key: reading every stored version of a
  domain with all 77 columns to then keep one blew the 6 GB server ceiling
  on the repair of the first run (126K domains, 2026-10-07).
  """
  # The VALUES column is Float64 and cast in the select: a literal such as
  # 0.33 "cannot be represented as Nullable(Float32)" to ClickHouse's
  # VALUES parser (Code 69), which failed every batch of the resumed run
  # on 2026-10-07 before a row was written.
  @spec insert_sql([String.t()], [{String.t(), String.t(), String.t(), number() | nil, String.t()}]) :: String.t()
  def insert_sql(cols, verdicts) do
    select =
      Enum.map_join(cols, ", ", fn
        "enriched_at" -> "now() AS enriched_at"
        "worker" -> "'master' AS worker"
        "http_status" -> "CAST(NULL AS Nullable(Int32)) AS http_status"
        "http_error" -> "'' AS http_error"
        "business_model" -> "v.bm AS business_model"
        "industry" -> "v.ind AS industry"
        "classification_confidence" -> "CAST(v.conf AS Nullable(Float32)) AS classification_confidence"
        "classification_source" -> "v.src AS classification_source"
        "http_observed" -> "0 AS http_observed"
        "pipeline_version" -> "'#{@version}' AS pipeline_version"
        c -> "d.#{c}"
      end)

    values =
      Enum.map_join(verdicts, ", ", fn {d, bm, ind, conf, src} ->
        "(#{lit(d)}, #{lit(bm)}, #{lit(ind)}, #{if(is_number(conf), do: Float.round(conf * 1.0, 2), else: "NULL")}, #{lit(src)})"
      end)

    domains = Enum.map_join(verdicts, ", ", fn {d, _, _, _, _} -> lit(d) end)

    """
    INSERT INTO #{LS.Schema.Tables.enrich_log()} (#{Enum.join(cols, ", ")})
    SELECT #{select}
    FROM (SELECT * FROM #{LS.Schema.Tables.enrich_log()}
          WHERE (domain, enriched_at) IN (
            SELECT domain, max(enriched_at) FROM #{LS.Schema.Tables.enrich_log()}
            WHERE domain IN (#{domains}) AND pipeline_version NOT LIKE 'backfill-%' GROUP BY domain)) AS d
    JOIN (SELECT * FROM VALUES('domain String, bm String, ind String, conf Nullable(Float64), src String', #{values})) AS v
      ON d.domain = v.domain
    """
  end

  defp lit(s), do: "'" <> (s |> to_string() |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"

  # The last domain of a page batch may continue into the next batch
  # (several stored versions). Drop it unless the batch was the last one,
  # so the cursor never splits a domain.
  def trim_split_domain(pages, batch) when length(pages) < batch,
    do: {dedupe(pages), (List.last(pages) || %{domain: ""}).domain}

  def trim_split_domain(pages, _batch) do
    last = List.last(pages).domain
    kept = Enum.reject(pages, &(&1.domain == last))
    {dedupe(kept), (List.last(kept) || %{domain: last}).domain}
  end

  defp dedupe(pages) do
    pages
    |> Enum.group_by(& &1.domain)
    |> Enum.map(fn {_, vs} -> Enum.max_by(vs, & &1.fetched_at) end)
    |> Enum.sort_by(& &1.domain)
  end

  # ── ClickHouse ────────────────────────────────────────────────────────

  defp fetch_pages(cursor, batch) do
    sql = """
    SELECT domain, toString(http_fetched_at), http_header_texts, http_body_texts, http_footer_texts
    FROM #{LS.Schema.Tables.http_pages()}
    WHERE page_kind = 'home' AND domain > {cursor:String}
    ORDER BY domain, page_kind
    LIMIT {n:UInt32}
    """

    case LS.Clickhouse.query(sql, %{cursor: cursor, n: batch}) do
      {:ok, rows} when is_list(rows) ->
        {:ok, Enum.map(rows, fn [d, at, h, b, f] -> %{domain: d, fetched_at: at, header: h, body: b, footer: f} end)}

      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, r} -> {:error, r}
    end
  end

  defp fetch_businesses([]), do: {:ok, %{}}

  defp fetch_businesses(domains) do
    list = Enum.map_join(domains, ",", &("'" <> String.replace(&1, ~r/['\\]/, "") <> "'"))

    sql = """
    SELECT domain, business_model, toString(http_last_checked_at), is_junk, http_title, http_h1, http_meta_description,
      arrayStringConcat(http_nav_links, '|'), arrayStringConcat(http_tech, '|'), http_apps, http_schema_type,
      http_address, http_phone, arrayStringConcat(http_pages_found, '|'), ctl_tld, arrayStringConcat(rdap_nameservers, '|'),
      arrayStringConcat(dns_mx, '|'), dns_dmarc, dns_dkim, dns_bimi, dns_ms_enterprise, last_http_status
    FROM #{LS.Schema.Tables.businesses()} WHERE domain IN (#{list})
    """

    case LS.Clickhouse.query(sql) do
      {:ok, rows} when is_list(rows) ->
        {:ok,
         Map.new(rows, fn [d, bm, checked, junk, title, h1, meta, nav, tech, apps, schema, addr, phone, pages, tld, ns, mx, dmarc, dkim, bimi, ms, status] ->
           {d, %{domain: d, business_model: bm, http_last_checked_at: checked, is_junk: junk, http_title: title, http_h1: h1,
                 http_meta_description: meta, http_nav_links: nav, http_tech: tech, http_apps: apps, http_schema_type: schema,
                 http_address: addr, http_phone: phone, http_pages: pages, ctl_tld: tld, rdap_nameservers: ns, dns_mx: mx,
                 dns_dmarc: dmarc, dns_dkim: dkim, dns_bimi: bimi, dns_ms_enterprise: ms, last_http_status: status}}
         end)}

      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, r} -> {:error, r}
    end
  end

  defp insert_verdicts(verdicts) do
    with {:ok, cols} <- log_columns(),
         {:ok, _} <- LS.Clickhouse.query_raw(insert_sql(cols, verdicts), 120_000) do
      :ok
    else
      {:error, r} -> Logger.warning("[BACKFILL] insert of #{length(verdicts)} verdicts failed: #{inspect(r)}"); {:error, r}
      other -> Logger.warning("[BACKFILL] insert of #{length(verdicts)} verdicts failed: #{inspect(other)}"); {:error, other}
    end
  end

  # The insertable columns of enrich_log, read once from the server (the
  # same pattern as LS.Recrawl.Liveness): the list is the table's, not a
  # copy in code that drifts from it.
  defp log_columns do
    case :persistent_term.get({__MODULE__, :columns}, nil) do
      nil ->
        sql =
          "SELECT name FROM system.columns WHERE database = currentDatabase() " <>
            "AND table = '#{LS.Schema.Tables.enrich_log()}' AND default_kind != 'MATERIALIZED' ORDER BY position"

        case LS.Clickhouse.query_raw(sql, 10_000) do
          {:ok, rows} when rows != [] ->
            cols = Enum.map(rows, fn [n] -> n end)
            :persistent_term.put({__MODULE__, :columns}, cols)
            {:ok, cols}

          {:ok, []} -> {:error, :no_columns}
          err -> err
        end

      cols ->
        {:ok, cols}
    end
  end

  # ── ML over the fleet ─────────────────────────────────────────────────

  # The workers already hold the head; the master lends them the texts in
  # chunks and keeps its own cores for ClickHouse. A chunk whose node fails
  # falls back to the local head.
  defp ml_batch([]), do: %{}

  defp ml_batch(pairs) do
    nodes = Enum.filter(Node.list(), &String.starts_with?(Atom.to_string(&1), "worker_"))
    chunks = Enum.chunk_every(pairs, @ml_chunk)

    chunks
    |> Enum.with_index()
    |> Task.async_stream(
      fn {chunk, i} ->
        texts = Enum.map(chunk, &elem(&1, 1))
        results = classify_remote(pick(nodes, i), texts)
        Enum.zip(Enum.map(chunk, &elem(&1, 0)), results)
      end,
      max_concurrency: max(min(length(nodes), 10), 1), timeout: 180_000, on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, zipped} -> zipped
      _ -> []
    end)
    |> Map.new()
  end

  defp pick([], _), do: nil
  defp pick(nodes, i), do: Enum.at(nodes, rem(i, length(nodes)))

  defp classify_remote(nil, texts), do: LS.ML.Classifier.classify_batch(texts)

  defp classify_remote(node, texts) do
    :erpc.call(node, LS.ML.Classifier, :classify_batch, [texts], 150_000)
  rescue
    _ -> LS.ML.Classifier.classify_batch(texts)
  catch
    _, _ -> LS.ML.Classifier.classify_batch(texts)
  end

  # ── small helpers ─────────────────────────────────────────────────────

  defp put_stats(stats), do: :persistent_term.put(@stats_key, stats)
  defp now_s, do: System.system_time(:second)
end
