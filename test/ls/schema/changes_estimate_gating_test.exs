defmodule LS.Schema.ChangesEstimateGatingTest do
  use ExUnit.Case, async: true

  alias LS.Schema.Changes

  @moduledoc """
  2026-10-03: on 10-02 the change log recorded 24K revenue-bracket and 14K
  business-model changes, and only 34% and 47% of them coincided with any
  fact changing on the same domain that day; the rest (13.8K "<$1M" to
  "$1M-$10M" in one day) was the estimator re-reading the same evidence.
  An estimate change is now recorded only next to a fact change of the
  same domain in the same pass. The statement was executed against the
  local harness on a 300-row copy of businesses before this shipped.
  """

  test "estimate events are kept only when the same row also carries a fact event" do
    sql = Changes.detect_sql("tmp_x")
    assert sql =~ "ARRAY JOIN arrayFilter(t -> NOT startsWith(t.1, 'estimated_') OR arrayExists(u -> NOT startsWith(u.1, 'estimated_'), _all), arrayConcat("
    assert sql =~ ") AS _all) AS ch"
  end

  test "every tracked column is still covered and the join is unchanged" do
    sql = Changes.detect_sql("tmp_x")
    assert sql =~ "INSERT INTO changes_log (domain, field, change, value, prev_value, changed_at)"
    for {name, _, _} <- LS.Schema.Columns.tracked(), do: assert(sql =~ "'#{name}'", "detection misses #{name}")
  end

  test "the SELECT parses on a ClickHouse harness when one is reachable" do
    case LS.Clickhouse.query_raw("SELECT 1", 2_000) do
      {:ok, _} ->
        select = Changes.detect_sql("businesses") |> String.replace(~r/\AINSERT INTO \S+ \([^)]*\)\n/, "")
        assert {:ok, _} = LS.Clickhouse.query_raw("EXPLAIN SYNTAX " <> select, 20_000)

      _ ->
        IO.puts("\n[changes] no ClickHouse harness, parse not checked")
    end
  end
end
