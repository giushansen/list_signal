defmodule LSWeb.StoreRowShapeTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Store rows are self-describing (2026-09-07). The store page and the
  lookup tool used to index a `SELECT *` on domains_current by
  LS.Cluster.Inserter.columns/0; the inserter list gained nine columns
  that domains_current does not have, so every field after dns_cname read
  its neighbour (titles rendered as page lists for a day) and a float
  reached decode_html/1 once the shift crossed classification_confidence.
  """

  test "a ClickHouse store row is a map keyed by the table's own columns" do
    if match?({:ok, _}, LS.Clickhouse.query_raw("SELECT 1")) do
      {:ok, [[d]]} = LS.Clickhouse.query_raw("SELECT domain FROM domains_current WHERE http_title != '' LIMIT 1")
      {:ok, [row]} = LS.Clickhouse.get_store(d)
      assert is_map(row)
      assert is_binary(row[:http_title]) and row[:http_title] != ""
      assert row[:domain] == d
      refute is_binary(row[:classification_confidence]) and row[:classification_confidence] =~ ~r/^[a-z]/i
      cols = LS.Clickhouse.domains_current_columns()
      assert :http_title in cols and :enriched_at == hd(cols)
      refute :http_fingerprint in cols, "domains_current has no fingerprint column; the inserter list is not its key"
    end
  end

  test "no store consumer indexes a ClickHouse row by inserter position any more" do
    store = File.read!("lib/ls_web/controllers/store_controller.ex")
    refute store =~ "Enum.at(row, Map.get(col_idx"
    assert store =~ "%{} -> row"
    lookup = File.read!("lib/ls/tools/lookup.ex")
    # The fresh path reads the map; the ETS-cached path keeps its list in
    # inserter order, which is the order it was built in.
    assert lookup =~ "row_to_response(row, domain, false)"
    assert lookup =~ "defp parse_row(row, domain) when is_list(row)"
  end
end
