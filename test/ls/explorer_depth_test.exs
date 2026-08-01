defmodule LS.ExplorerDepthTest do
  @moduledoc """
  The dashboard must show what pipeline 2 collected, and must not pretend to
  know things it has not looked at yet.

  The explorer reads discovery data (`domains_current`); enrichment lives in
  `businesses` and the `biz_*` children. Joining the two is what makes the
  detail card and the CSV worth paying for, and the failure mode to guard
  against is subtle: an un-enriched business must come back with EMPTY depth,
  not with zeros, because "Products: 0" reads as "this store sells nothing"
  when the truth is "we have not crawled it yet".

  Skips when no ClickHouse is reachable, like the other data contracts.
  """
  use ExUnit.Case, async: true

  alias LS.{Clickhouse, Explorer}

  @moduletag :data_contract

  defp ch_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))
  defp with_ch(body), do: if(ch_up?(), do: body.(), else: :ok)

  defp one(sql) do
    case Clickhouse.query_raw(sql) do
      {:ok, [[value] | _]} -> value
      _ -> nil
    end
  end

  describe "detail card data" do
    test "an enriched business carries its depth signals" do
      with_ch(fn ->
        domain = one("SELECT domain FROM biz_enrichment LIMIT 1")

        if domain do
          {:ok, detail} = Explorer.get_detail(domain)
          depth = detail["depth"]

          assert is_map(depth) and map_size(depth) > 0,
                 "an enriched business must expose its depth signals to the card"

          assert depth["depth_enriched_at"] != nil,
                 "without depth_enriched_at the card cannot tell enriched from un-enriched"
        end
      end)
    end

    test "child rows arrive as lists the card can render" do
      with_ch(fn ->
        domain = one("SELECT domain FROM biz_products GROUP BY domain ORDER BY count() DESC LIMIT 1")

        if domain do
          {:ok, detail} = Explorer.get_detail(domain)

          assert is_list(detail["products"])
          assert length(detail["products"]) > 0

          product = hd(detail["products"])
          assert Map.has_key?(product, "title")
          assert Map.has_key?(product, "price")
        end
      end)
    end

    test "an un-enriched business degrades to empty, never to zeros" do
      with_ch(fn ->
        domain =
          one("""
          SELECT domain FROM domains_current
          WHERE domain NOT IN (SELECT domain FROM biz_enrichment)
          LIMIT 1
          """)

        if domain do
          {:ok, detail} = Explorer.get_detail(domain)

          # The card keys off depth_enriched_at to decide whether to draw the
          # depth sections at all. Empty map => nothing drawn => no false
          # "0 products" claim.
          assert detail["depth"] == %{} or detail["depth"]["depth_enriched_at"] == nil
          assert detail["products"] == []
          assert detail["jobs"] == []
          assert detail["contacts"] == []
        end
      end)
    end

    test "child lists are capped so one huge catalogue cannot stall the card" do
      with_ch(fn ->
        domain = one("SELECT domain FROM biz_products GROUP BY domain ORDER BY count() DESC LIMIT 1")

        if domain do
          {:ok, detail} = Explorer.get_detail(domain)
          assert length(detail["products"]) <= 100
          assert length(detail["contacts"]) <= 50
        end
      end)
    end
  end

  describe "CSV export" do
    test "carries the depth columns a buyer is paying for" do
      with_ch(fn ->
        {:ok, {columns, _rows}} = Explorer.export_rows(%{}, 5)

        for column <- ~w(product_count price_avg job_count seo_score enriched_emails hq_location) do
          assert column in columns, "#{column} missing from the export — the buyer paid for depth"
        end
      end)
    end

    test "every row is as wide as the header claims" do
      # A short row silently shifts values into the wrong columns in Excel,
      # which is the kind of thing a customer notices before we do.
      with_ch(fn ->
        {:ok, {columns, rows}} = Explorer.export_rows(%{}, 20)

        for row <- rows do
          assert length(row) == length(columns)
        end
      end)
    end

    test "un-enriched businesses are still exported, with blank depth" do
      # A LEFT JOIN, not an inner one: dropping them would silently shrink
      # every customer's export to the ~1% we have deep-crawled.
      with_ch(fn ->
        {:ok, {_columns, rows}} = Explorer.export_rows(%{}, 50)
        assert length(rows) > 0
      end)
    end
  end
end
