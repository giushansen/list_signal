defmodule Mix.Tasks.Ls.GoldenEval do
  @shortdoc "Score a labeled golden-set CSV against pipeline predictions"

  @moduledoc """
  Scores a hand-labeled golden set (see `analysis/golden_set/README.md`):

      mix ls.golden_eval                       # newest analysis/golden_set/*.csv
      mix ls.golden_eval path/to/golden.csv

  Prints junk rate, per-class precision, confidence-band calibration and
  revenue-bracket accuracy. Purely offline — reads only the CSV.
  """

  use Mix.Task

  @impl true
  def run(args) do
    path = List.first(args) || newest_default()

    case LS.GoldenSet.parse(path) do
      {:ok, rows} ->
        Mix.shell().info("Scoring #{path}\n")
        Mix.shell().info(rows |> LS.GoldenSet.score() |> LS.GoldenSet.format())

      {:error, reason} ->
        Mix.raise("Cannot read #{path}: #{inspect(reason)}")
    end
  end

  defp newest_default do
    case Path.wildcard("analysis/golden_set/golden_set_v*.csv") |> Enum.sort() |> List.last() do
      nil -> Mix.raise("No golden set found under analysis/golden_set/ — pass a path explicitly.")
      path -> path
    end
  end
end
