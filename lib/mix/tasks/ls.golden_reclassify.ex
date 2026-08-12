defmodule Mix.Tasks.Ls.GoldenReclassify do
  @shortdoc "Re-run the classifier on golden-set cached HTML; print before/after"

  @moduledoc """
  Measures a classifier change against a frozen golden set:

      mix ls.golden_reclassify GOLDEN.csv PAGES_DIR

  `PAGES_DIR` holds one `<domain>.html` per golden row (a raw homepage body,
  as fetched when the set was labeled) and optionally `<domain>.meta` whose
  first tab-separated field is the final HTTP status. Rows without a cached
  page are skipped and counted — a dead domain has nothing to reclassify.

  BEFORE numbers come from the CSV's `predicted_*` columns (what production
  shipped when the set was sampled — heuristic + ML tier). AFTER numbers are
  the current heuristic re-run offline via
  `LS.Pipeline.classify_signals_from_html/2` — no ML tier and no response
  headers, so AFTER is slightly handicapped; treat gains as real and losses
  as "check whether the ML tier or a header signal used to save this row".

  Truth per row: `predicted_model` when `model_ok=y`, else `true_model`
  (which may be an invented class like LocalBusiness — that's the point).
  Junk truth is `is_real_business=n`.

  Caveat printed in the output: junk-rule gains are partly in-sample — some
  detector strings were added FROM this set's junk rows. The next golden
  version is the out-of-sample check.
  """

  use Mix.Task

  alias LS.HTTP.BusinessClassifier

  @impl true
  def run(["--ml" | rest]), do: do_run(rest, ml: true)
  def run(args), do: do_run(args, ml: false)

  defp do_run([csv_path, pages_dir], opts) do
    ml? = opts[:ml] and start_ml()
    if opts[:ml] and not ml?, do: Mix.shell().error("ML tier failed to load — falling back to heuristic-only")
    run_reclassify(csv_path, pages_dir, ml?)
  end

  defp do_run(_, _), do: Mix.raise("Usage: mix ls.golden_reclassify [--ml] GOLDEN.csv PAGES_DIR")

  # The ML tier bypasses the heuristic cutoff in production (merge keeps ML
  # output at any merged confidence), so a heuristic-only AFTER structurally
  # undercounts coverage — measured 2026-08-12: 86% prod coverage vs 15%
  # heuristic-only offline. --ml reproduces the real shipping path.
  defp start_ml do
    Mix.Task.run("app.start")

    Enum.find_value(1..60, false, fn _ ->
      if LS.ML.Classifier.ready?(), do: true, else: (Process.sleep(2_000) && nil)
    end)
  end

  defp run_reclassify(csv_path, pages_dir, ml?) do
    {:ok, rows} = LS.GoldenSet.parse(csv_path)
    labeled = Enum.filter(rows, &(get(&1, "is_real_business") != ""))

    results =
      Enum.flat_map(labeled, fn row ->
        domain = get(row, "domain")
        html_path = Path.join(pages_dir, domain <> ".html")

        case File.read(html_path) do
          {:ok, body} when byte_size(body) > 0 ->
            status = read_status(Path.join(pages_dir, domain <> ".meta"))
            tld = domain |> String.split(".") |> List.last() || ""

            signals =
              LS.Pipeline.classify_signals_from_html(body,
                domain: domain, tld: tld, http_status: status)

            [%{row: row, junk: BusinessClassifier.junk_reason(signals),
               after: classify_full(signals, ml?)}]

          _ ->
            # 0-byte cache file = server answered with an empty body; that IS
            # a fetch result, so synthesize empty signals rather than skip.
            if File.exists?(html_path) do
              signals = LS.Pipeline.classify_signals_from_html("",
                domain: domain, http_status: read_status(Path.join(pages_dir, domain <> ".meta")))
              [%{row: row, junk: BusinessClassifier.junk_reason(signals),
                 after: BusinessClassifier.classify(signals)}]
            else
              []
            end
        end
      end)

    skipped = length(labeled) - length(results)
    Mix.shell().info("Reclassified #{length(results)}/#{length(labeled)} labeled rows (#{skipped} without cached HTML — dead/unfetched)\n")

    report_junk(results)
    report_models(results)
    report_diffs(results)
  end


  # ── junk ──────────────────────────────────────────────────────────────────

  defp report_junk(results) do
    junk_rows = Enum.filter(results, &(get(&1.row, "is_real_business") == "n"))
    real_rows = Enum.filter(results, &(get(&1.row, "is_real_business") == "y"))

    caught = Enum.count(junk_rows, &(&1.junk != ""))
    false_junk = Enum.filter(real_rows, &(&1.junk != ""))

    Mix.shell().info("""
    Junk detector (in-sample caveat: several rules came from these very rows):
      recall    #{caught}/#{length(junk_rows)} labeled-junk rows detected
      false     #{length(false_junk)} real businesses wrongly junked#{format_list(false_junk)}
    """)
  end

  # ── model precision before/after ──────────────────────────────────────────

  defp report_models(results) do
    real = Enum.filter(results, &(get(&1.row, "is_real_business") == "y"))

    before_pairs =
      for r <- real, get(r.row, "predicted_model") != "", do: {get(r.row, "predicted_model"), truth(r.row)}

    after_pairs =
      for r <- real, r.after.business_model != "", do: {r.after.business_model, truth(r.row)}

    Mix.shell().info("Model precision (real rows with cached HTML):")
    Mix.shell().info("  BEFORE (prod predictions at sampling time)")
    print_precision(before_pairs)
    Mix.shell().info("  AFTER (current heuristic, offline — no ML tier/headers)")
    print_precision(after_pairs)

    known = Enum.filter(real, &(truth(&1.row) != ""))
    b_cov = Enum.count(known, &(get(&1.row, "predicted_model") != ""))
    a_cov = Enum.count(known, &(&1.after.business_model != ""))
    b_ok = Enum.count(known, &(get(&1.row, "predicted_model") == truth(&1.row)))
    a_ok = Enum.count(known, &(&1.after.business_model == truth(&1.row)))
    n = max(length(known), 1)

    Mix.shell().info("""
      overall (n=#{n} truth-known real rows):
        coverage  before #{pct(b_cov / n)}  after #{pct(a_cov / n)}
        accuracy  before #{pct(b_ok / n)}   after #{pct(a_ok / n)}
    """)
  end

  defp print_precision(pairs) do
    pairs
    |> Enum.filter(fn {_, t} -> t != "" end)
    |> Enum.group_by(fn {pred, _} -> pred end)
    |> Enum.map(fn {class, ps} ->
      ok = Enum.count(ps, fn {p, t} -> p == t end)
      {class, ok, length(ps)}
    end)
    |> Enum.sort()
    |> Enum.each(fn {class, ok, n} ->
      Mix.shell().info("    #{String.pad_trailing(class, 14)} #{pct(ok / n)}  (#{ok}/#{n})")
    end)
  end

  # ── per-domain changes, so a regression is a name, not a percentage ──────

  defp report_diffs(results) do
    diffs =
      results
      |> Enum.filter(fn r ->
        get(r.row, "is_real_business") == "y" and
          r.after.business_model != get(r.row, "predicted_model")
      end)
      |> Enum.map(fn r ->
        t = truth(r.row)
        was = get(r.row, "predicted_model")
        now = r.after.business_model
        mark = cond do
          now == t and was != t -> "FIXED"
          was == t and now != t -> "BROKE"
          now == "" -> "dropped"
          true -> "moved"
        end
        "    #{mark}  #{get(r.row, "domain")}: #{empty(was)} -> #{empty(now)} (truth: #{empty(t)})"
      end)

    Mix.shell().info("Changed predictions (#{length(diffs)}):\n" <> Enum.join(diffs, "\n"))
  end

  # Same tiering as LS.Pipeline.enrich/2: ML only when the heuristic is
  # under-confident and there is enough text to embed.
  defp classify_full(signals, ml?) do
    res = BusinessClassifier.classify(signals)

    ml_text =
      [signals.http_title, signals.h1, signals.http_meta_description, signals.body_text]
      |> Enum.join(" ")
      |> String.trim()

    if ml? and res.confidence < 0.55 and byte_size(ml_text) > 20 do
      LS.Pipeline.merge_classification(res, LS.ML.Classifier.classify(ml_text))
    else
      res
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp truth(row) do
    if get(row, "model_ok") == "y", do: get(row, "predicted_model"), else: get(row, "true_model")
  end

  defp read_status(meta_path) do
    with {:ok, meta} <- File.read(meta_path),
         [code | _] <- String.split(meta, "\t"),
         {status, _} <- Integer.parse(String.trim(code)) do
      status
    else
      _ -> 200
    end
  end

  defp get(row, key), do: row |> Map.get(key, "") |> String.trim()
  defp pct(r), do: "#{Float.round(r * 100, 1)}%"
  defp empty(""), do: "(none)"
  defp empty(v), do: v

  defp format_list([]), do: ""
  defp format_list(rows), do: ": " <> Enum.map_join(rows, ", ", &(get(&1.row, "domain") <> "=" <> &1.junk))
end
