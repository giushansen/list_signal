defmodule LS.GoldenSet do
  @moduledoc """
  Scores a hand-labeled golden-set CSV against the pipeline's predictions.

  The golden set (`analysis/golden_set/golden_set_v<N>_<date>.csv`) is a
  stratified sample of prod `businesses` rows that the owner labels by hand:
  is it a real business, is the predicted model/industry right, what revenue
  bracket does it look like. This module turns those labels into the numbers
  that drive recalibration — per-class precision, junk rate, confidence-band
  accuracy — so classifier changes are measured against a fixed reference
  instead of eyeballed. Never tune the classifier and the golden set in the
  same change: grow v(N+1) from v(N)'s disagreements, then tune against it.

  Offline on purpose: reads only the CSV, no ClickHouse, so it runs in tests
  and on any machine.
  """

  @doc """
  Parse a golden-set CSV into a list of maps keyed by the header row.

  Minimal RFC-4180: quoted fields may contain commas/newlines, `""` escapes a
  quote. Returns `{:ok, rows}` or `{:error, reason}`.
  """
  def parse(path) do
    with {:ok, content} <- File.read(path) do
      case split_records(content) do
        [] -> {:error, :empty}
        [header | rows] ->
          keys = Enum.map(header, &String.trim/1)
          {:ok, Enum.map(rows, fn r -> keys |> Enum.zip(pad(r, length(keys))) |> Map.new() end)}
      end
    end
  end

  @doc """
  Score labeled rows. Rows with an empty `is_real_business` are unlabeled and
  ignored, so this works on a partially filled CSV too.
  """
  def score(rows) do
    labeled = Enum.filter(rows, &(get(&1, "is_real_business") != ""))

    junk = Enum.count(labeled, &(get(&1, "is_real_business") == "n"))
    real = Enum.filter(labeled, &(get(&1, "is_real_business") == "y"))

    %{
      total: length(rows),
      labeled: length(labeled),
      junk_rate: ratio(junk, length(labeled)),
      model_precision: per_class_precision(real, "predicted_model", "model_ok"),
      industry_precision: per_class_precision(real, "predicted_industry", "industry_ok"),
      band_accuracy: band_accuracy(real),
      revenue_accuracy: revenue_accuracy(real),
      unclassified_real: unclassified_real(labeled)
    }
  end

  @doc "Render a score map as a plain-text report."
  def format(s) do
    """
    Golden set: #{s.labeled}/#{s.total} rows labeled
    Junk rate (not a real business): #{pct(s.junk_rate)}
    Unclassified bucket: #{s.unclassified_real} real businesses we failed to classify

    Business-model precision (real businesses only):
    #{format_classes(s.model_precision)}
    Industry precision:
    #{format_classes(s.industry_precision)}
    Accuracy by confidence band (model): #{format_bands(s.band_accuracy)}
    Revenue bracket accuracy: #{format_revenue(s.revenue_accuracy)}
    """
  end

  # ── scoring ──────────────────────────────────────────────────────────────

  defp per_class_precision(rows, pred_col, ok_col) do
    rows
    |> Enum.filter(&(get(&1, pred_col) != "" and get(&1, ok_col) in ["y", "n"]))
    |> Enum.group_by(&get(&1, pred_col))
    |> Enum.map(fn {class, rs} ->
      ok = Enum.count(rs, &(get(&1, ok_col) == "y"))
      {class, %{n: length(rs), precision: ratio(ok, length(rs))}}
    end)
    |> Enum.sort_by(fn {_, %{precision: p}} -> p end)
  end

  # Was the confident tier actually more accurate than the near-cutoff tier?
  # If not, the confidence score isn't calibrated and thresholds are fiction.
  defp band_accuracy(rows) do
    rows
    |> Enum.filter(&(get(&1, "model_ok") in ["y", "n"] and get(&1, "model_confidence") != ""))
    |> Enum.group_by(fn r ->
      case Float.parse(get(r, "model_confidence")) do
        {c, _} when c >= 0.68 -> :high
        {_, _} -> :low
        :error -> :low
      end
    end)
    |> Map.new(fn {band, rs} ->
      {band, %{n: length(rs), accuracy: ratio(Enum.count(rs, &(get(&1, "model_ok") == "y")), length(rs))}}
    end)
  end

  defp revenue_accuracy(rows) do
    scored =
      Enum.filter(rows, &(get(&1, "true_revenue") != "" and get(&1, "predicted_revenue") != ""))

    exact = Enum.count(scored, &(get(&1, "predicted_revenue") == get(&1, "true_revenue")))
    %{n: length(scored), exact: ratio(exact, length(scored))}
  end

  defp unclassified_real(labeled) do
    Enum.count(labeled, fn r ->
      get(r, "bucket") == "unclassified" and get(r, "is_real_business") == "y" and
        get(r, "true_model") != ""
    end)
  end

  # ── formatting ───────────────────────────────────────────────────────────

  defp format_classes([]), do: "  (none labeled yet)"
  defp format_classes(classes) do
    Enum.map_join(classes, "\n", fn {class, %{n: n, precision: p}} ->
      "  #{String.pad_trailing(class, 14)} #{pct(p)}  (n=#{n})"
    end)
  end

  defp format_bands(bands) when map_size(bands) == 0, do: "(none labeled yet)"
  defp format_bands(bands) do
    Enum.map_join([:low, :high], "  ", fn band ->
      case bands[band] do
        nil -> "#{band}: –"
        %{n: n, accuracy: a} -> "#{band}: #{pct(a)} (n=#{n})"
      end
    end)
  end

  defp format_revenue(%{n: 0}), do: "(none labeled yet)"
  defp format_revenue(%{n: n, exact: e}), do: "#{pct(e)} exact bracket (n=#{n})"

  defp pct(r), do: "#{Float.round(r * 100, 1)}%"
  defp ratio(_, 0), do: 0.0
  defp ratio(a, b), do: a / b

  # y/n flag columns compare case-insensitively ("Y" counts as "y"); class and
  # bracket names keep their case so the report shows "SaaS", not "saas".
  @flag_cols ~w(is_real_business model_ok industry_ok)
  defp get(row, key) when key in @flag_cols,
    do: row |> Map.get(key, "") |> String.trim() |> String.downcase()
  defp get(row, key), do: row |> Map.get(key, "") |> String.trim()

  # ── CSV parsing ──────────────────────────────────────────────────────────

  defp split_records(content) do
    {records, field, fields, state} =
      content
      |> String.replace("\r\n", "\n")
      |> String.graphemes()
      |> Enum.reduce({[], "", [], false}, fn ch, {recs, field, fields, in_q} ->
        case {ch, in_q} do
          {"\"", false} -> {recs, field, fields, true}
          {"\"", true} -> {recs, field <> "\"", fields, :maybe_close}
          {c, :maybe_close} when c == "\"" -> {recs, field, fields, true}
          {c, :maybe_close} -> reduce_char(c, {recs, String.slice(field, 0..-2//1), fields, false})
          {c, false} -> reduce_char(c, {recs, field, fields, false})
          {c, true} -> {recs, field <> c, fields, true}
        end
      end)

    # EOF right after a closing quote: the tentative quote is still buffered.
    field = if state == :maybe_close, do: String.slice(field, 0..-2//1), else: field
    records = if field != "" or fields != [], do: [Enum.reverse([field | fields]) | records], else: records
    records |> Enum.reverse() |> Enum.reject(&(&1 == [""]))
  end

  defp reduce_char(",", {recs, field, fields, _}), do: {recs, "", [field | fields], false}
  defp reduce_char("\n", {recs, field, fields, _}), do: {[Enum.reverse([field | fields]) | recs], "", [], false}
  defp reduce_char(c, {recs, field, fields, _}), do: {recs, field <> c, fields, false}

  defp pad(list, n) when length(list) >= n, do: Enum.take(list, n)
  defp pad(list, n), do: list ++ List.duplicate("", n - length(list))
end
