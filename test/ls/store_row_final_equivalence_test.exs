defmodule LS.StoreRowFinalEquivalenceTest do
  use ExUnit.Case, async: false

  @moduledoc """
  The public store page reads one row of `domains` without FINAL
  (2026-10-04). FINAL had been there since the first website commit
  (83c5224), when `domains_current` was a MaterializedView and FINAL was
  the only way to get newest-row-wins. The table is now a plain
  ReplacingMergeTree(enriched_at) keyed by domain, so the row with the
  newest `enriched_at` IS the row FINAL keeps, at 78 ms and 103 MB against
  116 ms and 169 MB (measured on prod the night a scraper at 1,000 pages a
  minute put ClickHouse at 350% CPU).

  That equivalence holds because of three properties of the table, and it
  stops holding the moment one of them changes: a sorting key with a
  second column (FINAL would then keep several rows per domain), a
  different version column, or a plain MergeTree (no dedup at all). These
  tests fail if any of them changes, so the cheap query is never left
  silently wrong.

  Checked on prod before shipping: 504 sampled domains with more than one
  row, zero rows differing between the two forms, and of 149,062 multi-row
  domains not one had its newest `enriched_at` shared by two rows, which
  is the only case where the two forms could pick differently.
  """

  @sample 200

  defp ch?, do: match?({:ok, _}, LS.Clickhouse.query_raw("SELECT 1", 2_000))

  defp one(sql) do
    case LS.Clickhouse.query_raw(sql, 60_000) do
      {:ok, [[v]]} -> v
      other -> flunk("query failed: #{inspect(other)} for #{sql}")
    end
  end

  test "the store row query asks for the newest version and never for FINAL" do
    sql = LS.Clickhouse.store_row_sql("shop.example")
    refute sql =~ "FINAL"
    assert sql =~ "ORDER BY enriched_at DESC LIMIT 1"
  end

  describe "against a real ClickHouse" do
    test "domains is still ReplacingMergeTree(enriched_at) sorted by domain alone" do
      if ch?() do
        # engine_full carries the version column; sorting_key carries the key.
        engine = one("SELECT engine_full FROM system.tables WHERE database = currentDatabase() AND name = 'domains'")
        key = one("SELECT sorting_key FROM system.tables WHERE database = currentDatabase() AND name = 'domains'")

        assert engine =~ "ReplacingMergeTree(enriched_at)",
               "the cheap store row assumes enriched_at is the version column, found: #{engine}"

        assert String.trim(key) == "domain",
               "FINAL keeps one row per sorting key; with #{key} it would keep several per domain and " <>
                 "ORDER BY enriched_at DESC LIMIT 1 would no longer be the same row"
      else
        IO.puts("\n[store row] no ClickHouse, engine contract not checked")
      end
    end

    test "no domain has two rows sharing its newest enriched_at, the only way the two forms could differ" do
      if ch?() do
        tied =
          one("""
          SELECT toInt32(countIf(tied > 1)) FROM (
            SELECT domain, countIf(enriched_at = mx) AS tied FROM (
              SELECT domain, enriched_at, max(enriched_at) OVER (PARTITION BY domain) AS mx
              FROM domains WHERE domain IN (SELECT domain FROM domains LIMIT 200000)
            ) GROUP BY domain HAVING count() > 1
          ) SETTINGS max_threads = 2
          """)

        assert tied == 0, "#{tied} domains have a tied newest version: the cheap row is then arbitrary"
      else
        IO.puts("\n[store row] no ClickHouse, ties not checked")
      end
    end

    test "get_store returns exactly the row FINAL would, on domains that have several" do
      if ch?() do
        # Domains with several rows are where the two forms could diverge. A
        # fully merged snapshot (the laptop harness is one part) has none, so
        # fall back to any domains: the comparison then still catches an
        # engine or sorting-key change, which is the regression that matters.
        {:ok, rows} =
          LS.Clickhouse.query_raw(
            "SELECT domain FROM domains WHERE domain IN (SELECT domain FROM domains LIMIT 200000) " <>
              "GROUP BY domain HAVING count() > 1 LIMIT #{@sample} SETTINGS max_threads = 2",
            60_000
          )

        {domains, kind} =
          case Enum.map(rows, &hd/1) do
            [] ->
              {:ok, any} = LS.Clickhouse.query_raw("SELECT domain FROM domains LIMIT #{@sample}", 60_000)
              {Enum.map(any, &hd/1), "single-row (this snapshot is fully merged)"}

            multi ->
              {multi, "multi-row"}
          end

        assert domains != [], "the domains table is empty: nothing to compare"
        IO.puts("\n[store row] comparing #{length(domains)} #{kind} domains")

        for d <- domains do
          {:ok, [cheap]} = LS.Clickhouse.get_store(d)

          final =
            case LS.Clickhouse.query_raw(
                   "SELECT * FROM domains FINAL WHERE domain = '#{LS.Clickhouse.escape_public(d)}' LIMIT 1",
                   60_000
                 ) do
              {:ok, [row]} -> LS.Clickhouse.domains_current_columns() |> Enum.zip(row) |> Map.new()
              other -> flunk("FINAL read failed for #{d}: #{inspect(other)}")
            end

          assert cheap == final, "#{d}: the cheap row differs from the row FINAL keeps"
        end
      else
        IO.puts("\n[store row] no ClickHouse, row equality not checked")
      end
    end
  end
end
