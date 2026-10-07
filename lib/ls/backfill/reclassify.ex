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
      LS.Backfill.Reclassify.status()
      LS.Backfill.Reclassify.stop()

  A domain whose last fetch is after `cutoff` was already judged by the
  new code and is skipped; so is a page flagged as junk. Rows are written
  with `worker` "master", `http_observed` 0 and no HTTP columns, so they
  can never win an HTTP fold, and `pipeline_version` "backfill-<sha>" so a
  label can be traced to this run. The compactor folds them on its next
  pass (five minutes).
  """

  require Logger

  alias LS.HTTP.BusinessClassifier

  @default_cutoff "2026-10-05 22:00:00"
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
      opts = Keyword.merge([cutoff: @default_cutoff, batch: 1000, pause_ms: 250, cursor: ""], opts)
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
    Logger.info("[BACKFILL] reclassify started cutoff=#{opts[:cutoff]} batch=#{opts[:batch]}")
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
          for p <- pages, b = biz[p.domain], eligible?(b, opts[:cutoff]) do
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

        rows = for {b, final, d} <- decisions, d != :same, do: row(b.domain, final)
        write = if rows == [], do: :ok, else: insert_rows(rows)

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

  @doc "A page is revisited when the new code has not seen it and it is not junk."
  def eligible?(b, cutoff), do: b.is_junk == "" and b.http_last_checked_at < cutoff

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

  @doc "The enrich_log row for one verdict: classification columns only."
  def row(domain, final) do
    %{
      domain: domain,
      enriched_at: now_str(),
      worker: "master",
      http_observed: 0,
      business_model: final.business_model,
      industry: final.industry,
      classification_confidence: final.confidence,
      classification_source: LS.Pipeline.classification_source(final, true),
      pipeline_version: "backfill-" <> LS.Version.sha()
    }
  end

  @insert_cols ~w(domain enriched_at worker http_observed business_model industry classification_confidence classification_source pipeline_version)

  @doc "The INSERT statement and one TabSeparated line per row."
  def insert_sql, do: "INSERT INTO #{LS.Schema.Tables.enrich_log()} (#{Enum.join(@insert_cols, ", ")}) FORMAT TabSeparated"

  def tsv_line(row) do
    @insert_cols
    |> Enum.map(fn c -> row |> Map.fetch!(String.to_existing_atom(c)) |> tsv_value() end)
    |> Enum.join("\t")
  end

  defp tsv_value(nil), do: "\\N"
  defp tsv_value(v) when is_float(v), do: Float.to_string(v)
  defp tsv_value(v) when is_integer(v), do: Integer.to_string(v)

  defp tsv_value(v) when is_binary(v),
    do: v |> String.replace("\\", "\\\\") |> String.replace("\t", "\\t") |> String.replace("\n", "\\n") |> String.replace("\r", "")

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

  defp insert_rows(rows) do
    case LS.Clickhouse.insert_raw(insert_sql(), Enum.map_join(rows, "\n", &tsv_line/1)) do
      :ok -> :ok
      {:error, r} -> Logger.warning("[BACKFILL] insert of #{length(rows)} rows failed: #{inspect(r)}"); {:error, r}
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
  defp now_str, do: NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)
end
