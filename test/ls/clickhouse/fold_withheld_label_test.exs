defmodule LS.Clickhouse.FoldWithheldLabelTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-07: the golden v6 classifier fixed Ecommerce precision mostly by
  withholding labels, and the product fold kept the last non-empty label,
  so 4.68M WooCommerce-only domains stayed Ecommerce at 97% in `businesses`
  while the new code labelled 26% of that pattern. A withheld label and a
  failed fetch looked identical to the fold. Now the classification unit
  follows the newest row that EVALUATED the page: a label, or source "none".
  """

  alias LS.Clickhouse.Compact

  test "the four classification columns fold on the evaluated condition, nothing else keys on the label alone" do
    sql = Compact.compact_sql_for_test(1_700_000_000)
    cond_sql = "(s_business_model != '' OR s_classification_source != '')"

    for col <- ~w(business_model industry classification_confidence classification_source) do
      assert sql =~ "argMaxIf(s_#{col}, s_enriched_at, #{cond_sql}) AS #{col}", col
    end

    refute sql =~ "s_enriched_at, s_business_model != '') AS"
  end

  test "a page that was read and declined clears the label; a failed fetch keeps it; legacy labels without a source still count (real ClickHouse)" do
    case LS.Clickhouse.query("SELECT 1") do
      {:ok, _} ->
        fold = fn rows ->
          values = Enum.map_join(rows, ", ", fn {ts, bm, src} -> "(#{ts}, '#{bm}', '#{src}')" end)

          {:ok, [[got]]} =
            LS.Clickhouse.query(
              "SELECT argMaxIf(bm, ts, #{Compact.evaluated_sql()}) FROM (SELECT c1 AS ts, c2 AS bm, c3 AS src, bm AS business_model, src AS classification_source FROM VALUES('c1 UInt32, c2 String, c3 String', #{values}))"
            )

          got
        end

        # Old label (pre-provenance, empty source), then a fresh evaluated row with no label: cleared.
        assert fold.([{1, "Ecommerce", ""}, {2, "", "none"}]) == ""
        # Old label, then a failed fetch (nothing evaluated): kept.
        assert fold.([{1, "Ecommerce", ""}, {2, "", ""}]) == "Ecommerce"
        # Cleared, then a later crawl labels it again: the newer label wins.
        assert fold.([{1, "Ecommerce", ""}, {2, "", "none"}, {3, "LocalBusiness", "heuristic"}]) == "LocalBusiness"
        # Only failed fetches after a withheld verdict: stays cleared.
        assert fold.([{1, "Ecommerce", "heuristic"}, {2, "", "none"}, {3, "", ""}]) == ""

      _ ->
        IO.puts("\n[fold withheld label] skipped: no ClickHouse reachable")
    end
  end
end
