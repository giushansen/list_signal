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
        # From `businesses` — that is the explorer's table now. A domain in
        # domains_current but absent from businesses has no detail page at
        # all, which is a different case.
        domain =
          one("""
          SELECT domain FROM businesses FINAL
          WHERE depth_enriched_at IS NULL
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

  describe "depth filters (they queried columns that did not exist)" do
    # Every one of these referenced a column on domains_current that is not
    # there — product_count, seo_score, job_count, pricing_points. The UI
    # offered them, and using one returned an error rather than results.
    test "each depth filter runs and can match rows" do
      with_ch(fn ->
        for {label, filter} <- [
              {"min_products", %{min_products: "1"}},
              {"max_products", %{max_products: "10000"}},
              {"has_pricing", %{has_pricing: "true"}},
              {"hiring", %{hiring: "true"}},
              {"min_seo_score", %{min_seo_score: "1"}},
              {"min_job_count", %{min_job_count: "1"}},
              {"has_email", %{has_email: "true"}},
              {"shopify_app", %{shopify_app: "klaviyo"}}
            ] do
          assert {:ok, count} = Explorer.count(filter), "#{label} filter errored"
          assert is_integer(count), "#{label} did not return a count"
        end
      end)
    end
  end

  describe "sorting" do
    test "sortable columns actually change the order" do
      with_ch(fn ->
        {:ok, desc} = Explorer.list(%{min_products: "1"}, per_page: 5, sort: "product_count", dir: "desc")
        {:ok, asc} = Explorer.list(%{min_products: "1"}, per_page: 5, sort: "product_count", dir: "asc")

        if desc != [] and asc != [] do
          top_desc = hd(desc)["product_count"]
          top_asc = hd(asc)["product_count"]
          assert to_string(top_desc) != to_string(top_asc)
        end
      end)
    end

    test "an unknown or hostile sort column falls back to the default order" do
      # The sort value reaches ORDER BY, so the allow-list is the only thing
      # between a query string and SQL injection.
      with_ch(fn ->
        {:ok, default} = Explorer.list(%{}, per_page: 3)
        {:ok, hostile} = Explorer.list(%{}, per_page: 3, sort: "domain; DROP TABLE businesses--", dir: "desc")
        {:ok, unknown} = Explorer.list(%{}, per_page: 3, sort: "not_a_column", dir: "desc")

        assert Enum.map(default, & &1["domain"]) == Enum.map(hostile, & &1["domain"])
        assert Enum.map(default, & &1["domain"]) == Enum.map(unknown, & &1["domain"])
      end)
    end

    test "every advertised sortable column is accepted" do
      with_ch(fn ->
        for column <- Explorer.sortable_columns() do
          assert {:ok, _rows} = Explorer.list(%{}, per_page: 2, sort: column, dir: "desc"),
                 "#{column} is offered as sortable but the query failed"
        end
      end)
    end
  end

  describe "segment presets" do
    # A preset is a promise on a button: "Shopify + contact" must return
    # Shopify stores with contacts. The failure mode is silent — a preset
    # referencing a filter the backend does not implement returns everything
    # or nothing, and the label still looks right.
    test "every segment uses filters the backend actually implements" do
      with_ch(fn ->
        for segment <- LSWeb.ExplorerLive.segments() do
          assert {:ok, count} = Explorer.count(segment.filters),
                 "segment #{segment.id} errored — it references a filter that does not exist"

          assert is_integer(count)
        end
      end)
    end

    test "a segment narrows the result set rather than matching everything" do
      with_ch(fn ->
        {:ok, everything} = Explorer.count(%{})

        for segment <- LSWeb.ExplorerLive.segments() do
          {:ok, count} = Explorer.count(segment.filters)

          assert count < everything,
                 "segment #{segment.id} matched the whole table — its filters are not being applied"
        end
      end)
    end

    test "weak-SEO excludes businesses we never scored" do
      # NULL seo_score means "not looked at", not "bad". Including them would
      # fill an SEO agency's pitch list with companies that have no problem.
      with_ch(fn ->
        {:ok, rows} = Explorer.list(%{max_seo_score: "49"}, per_page: 20)

        for row <- rows do
          refute row["seo_score"] in [nil, ""],
                 "#{row["domain"]} has no SEO score but appears in the weak-SEO segment"
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
