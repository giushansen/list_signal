defmodule LS.StoreRowSqlTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-04: the public store page's point read used FINAL on the
  58-column domains table, 169 MB and 116 ms per cold domain; the same row
  by the version column costs 103 MB and 78 ms. domains is
  ReplacingMergeTree(enriched_at), so the newest enriched_at IS the row
  FINAL would keep.
  """

  test "the store row is the newest version without FINAL" do
    sql = LS.Clickhouse.store_row_sql("shop.example")
    refute sql =~ "FINAL"
    assert sql =~ "WHERE domain = 'shop.example' ORDER BY enriched_at DESC LIMIT 1"
  end

  test "hostile domains are escaped" do
    sql = LS.Clickhouse.store_row_sql("a'b.example")
    refute sql =~ "= 'a'b.example'"
  end

  test "the speed probe measures the query the page runs" do
    src = File.read!("lib/ls/data_check.ex")
    assert src =~ ~s(SELECT domain FROM domains WHERE domain = 'google.com' ORDER BY enriched_at DESC LIMIT 1)
    refute src =~ "domains FINAL WHERE domain = 'google.com'"
  end
end
