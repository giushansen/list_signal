defmodule Mix.Tasks.Ls.GoldenReestimate do
  @moduledoc """
  Measures an estimator change against a frozen golden set:

      mix ls.golden_reestimate GOLDEN.csv ROWS.jsonl

  `ROWS.jsonl` holds one newest `enrich_log` row per golden domain
  (ClickHouse `JSONEachRow`, 64-bit integers unquoted), the same map the
  master's inserter hands to `LS.Revenue.Estimator.estimate/1`. BEFORE is
  what production shipped when the set was sampled (the CSV's
  `predicted_revenue`, and the row's `estimated_employees`); AFTER is the
  current estimator run offline on the stored row. Truth is `true_revenue`
  and `true_employees` on real businesses.

  Prints exact and within-one-bracket accuracy, the over/under split, and
  the exact rate per predicted bracket, so a change that trades one error
  for another is visible. Written 2026-10-05 for golden v6, where
  production's "$100M-$1B" was right 0 times in 25.
  """

  use Mix.Task

  @revenue ["<$1M", "$1M-$10M", "$10M-$100M", "$100M-$1B", "$1B+"]
  @employees ["1-10", "11-50", "51-500", "501-5000", "5000+"]

  @impl true
  def run([csv_path, rows_path]) do
    {:ok, golden} = LS.GoldenSet.parse(csv_path)
    rows = load_rows(rows_path)

    real =
      golden
      |> Enum.filter(&(get(&1, "is_real_business") == "y"))
      |> Enum.filter(&Map.has_key?(rows, get(&1, "domain")))

    Mix.shell().info("#{length(real)} real businesses with a stored row\n")

    after_est = Map.new(real, fn g -> {get(g, "domain"), LS.Revenue.Estimator.estimate(rows[get(g, "domain")])} end)

    report("REVENUE  before (production at sampling)", real, @revenue,
      fn g -> get(g, "predicted_revenue") end, fn g -> get(g, "true_revenue") end)

    report("REVENUE  after  (current estimator, offline)", real, @revenue,
      fn g -> after_est[get(g, "domain")].estimated_revenue end, fn g -> get(g, "true_revenue") end)

    report("EMPLOYEES before", real, @employees,
      fn g -> to_string(rows[get(g, "domain")][:estimated_employees] || "") end, fn g -> get(g, "true_employees") end)

    report("EMPLOYEES after", real, @employees,
      fn g -> after_est[get(g, "domain")].estimated_employees end, fn g -> get(g, "true_employees") end)
  end

  def run(_), do: Mix.raise("Usage: mix ls.golden_reestimate GOLDEN.csv ROWS.jsonl")

  defp report(title, real, order, pred_fn, true_fn) do
    pairs =
      for g <- real, t = true_fn.(g), t != "", p = pred_fn.(g) || "", do: {p, t}

    scored = Enum.filter(pairs, fn {p, _} -> p != "" end)
    n = length(pairs)
    cov = length(scored)
    idx = fn b -> Enum.find_index(order, &(&1 == b)) end
    exact = Enum.count(scored, fn {p, t} -> p == t end)
    within = Enum.count(scored, fn {p, t} -> abs(idx.(p) - idx.(t)) <= 1 end)
    over = Enum.count(scored, fn {p, t} -> idx.(p) > idx.(t) end)
    under = Enum.count(scored, fn {p, t} -> idx.(p) < idx.(t) end)

    Mix.shell().info(
      "#{title}: n=#{n} covered=#{cov} exact=#{pct(exact, cov)} within1=#{pct(within, cov)} over=#{over} under=#{under}"
    )

    for b <- order do
      ts = for {p, t} <- scored, p == b, do: t

      if ts != [] do
        ok = Enum.count(ts, &(&1 == b))
        dist = ts |> Enum.frequencies() |> Enum.sort_by(fn {t, _} -> idx.(t) end) |> Enum.map_join(" ", fn {t, c} -> "#{t}:#{c}" end)
        Mix.shell().info("    pred #{String.pad_trailing(b, 11)} n=#{String.pad_leading(to_string(length(ts)), 3)} exact=#{pct(ok, length(ts))}  true: #{dist}")
      end
    end

    Mix.shell().info("")
  end

  defp pct(_, 0), do: "n/a"
  defp pct(a, b), do: "#{Float.round(100 * a / b, 1)}%"

  # One row per domain, keyed by the inserter's own column atoms, so the
  # estimator sees exactly the map the master gives it.
  defp load_rows(path) do
    cols = LS.Cluster.Inserter.columns()

    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
    |> Map.new(fn obj ->
      # Array columns come back as lists; the worker's row carries them as
      # "a|b" strings, which is what the estimator's signals read.
      row = Map.new(cols, fn c -> {c, pipe(obj[Atom.to_string(c)])} end)
      {obj["domain"], row}
    end)
  end

  defp pipe(v) when is_list(v), do: Enum.map_join(v, "|", &to_string/1)
  defp pipe(v), do: v

  defp get(row, key), do: Map.get(row, key, "") |> to_string() |> String.trim()
end
