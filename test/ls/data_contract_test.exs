defmodule LS.DataContractTest do
  @moduledoc """
  Asserts the UI and the data still agree, against a real ClickHouse.

  The unit tests elsewhere prove that a filter option compiles to the SQL we
  intend. They cannot prove that SQL matches anything — that depends on what the
  enrichment pipeline actually wrote. Both production bugs this suite was added
  for were of exactly that shape:

    * /dashboard offered revenue bracket "$10M-$50M" while the estimator wrote
      "$10M-$100M" — valid SQL, 0 of 80M rows.
    * /tech/google-analytics rendered its aggregate's failure as "100+ stores,
      0 online" — a valid page full of fabricated numbers.

  Skipped automatically when no ClickHouse is reachable, so `mix test` stays
  green on a laptop. Run it where the data lives:

      # against production, from the laptop
      ssh -N -L 8123:127.0.0.1:8123 ls@45.63.7.58 &
      mix test test/ls/data_contract_test.exs

      # locally against the .ch/ harness
      bash .ch/start-local-ch.sh && mix test test/ls/data_contract_test.exs

  Every check is one grouped query per column rather than one query per option,
  so the whole suite is a handful of scans and safe to point at production.
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse
  alias LS.Explorer
  alias LS.Revenue.Estimator

  @moduletag :data_contract

  setup_all do
    unless clickhouse_up?() do
      IO.puts("\n[data contract] skipped — no ClickHouse reachable on 127.0.0.1:8123")
    end

    :ok
  end

  defp clickhouse_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))

  # Runs `body` only when a ClickHouse is reachable, so the suite is a no-op on
  # a laptop but a real contract check wherever the data lives.
  defp with_clickhouse(body), do: if(clickhouse_up?(), do: body.(), else: :ok)

  defp value_counts(sql) do
    {:ok, rows} = Clickhouse.query_raw(sql)
    Map.new(rows, fn [value, count] -> {value, count} end)
  end

  defp column_counts(column) do
    value_counts("""
    SELECT #{column} AS v, count() FROM domains_current WHERE #{column} != '' GROUP BY v
    """)
  end

  # An option that can never match is a dead end: the user cannot tell it apart
  # from a genuinely empty result, which is precisely how the revenue filter bug
  # went unnoticed.
  defp assert_all_offered_values_match(field, offered, counts) do
    dead = Enum.filter(offered, &(Map.get(counts, &1, 0) == 0))

    assert dead == [],
           "these #{field} options match 0 rows and must not be offered: #{inspect(dead)}\n" <>
             "values actually present: #{inspect(counts |> Map.keys() |> Enum.sort())}"
  end

  describe "filter options select real rows" do
    test "every revenue bracket the dropdown offers" do
      with_clickhouse(fn ->
        counts = column_counts("estimated_revenue")
        assert_all_offered_values_match(:revenue, Estimator.revenue_labels(), counts)
      end)
    end

    test "every employee bracket the dropdown offers" do
      with_clickhouse(fn ->
        counts = column_counts("estimated_employees")
        assert_all_offered_values_match(:employees, Estimator.employee_labels(), counts)
      end)
    end

    test "no stored bracket is missing from the dropdown" do
      with_clickhouse(fn ->
        for {column, labels} <- [
              {"estimated_revenue", Estimator.revenue_labels()},
              {"estimated_employees", Estimator.employee_labels()}
            ] do
          orphans = column_counts(column) |> Map.keys() |> Enum.sort() |> Kernel.--(labels)

          assert orphans == [],
                 "#{column} holds values the UI cannot filter on: #{inspect(orphans)}"
        end
      end)
    end

    test "every tech the dropdown offers" do
      with_clickhouse(fn ->
        {:ok, offered} = Explorer.distinct_techs("", 800)

        counts =
          value_counts("""
          SELECT arrayJoin(splitByChar('|', http_tech)) AS v, count()
          FROM domains_current WHERE http_tech != '' GROUP BY v
          """)

        assert_all_offered_values_match(:tech, offered, counts)
      end)
    end

    test "every data-derived dropdown (country, language, business model, industry)" do
      with_clickhouse(fn ->
        for {field, column} <- [
              {:country, "inferred_country"},
              {:business_model, "business_model"},
              {:industry, "industry"}
            ] do
          {:ok, offered} = Explorer.distinct_by_count(column, 300)
          assert_all_offered_values_match(field, offered, column_counts(column))
        end

        # Language is stored with region subtags ("en-US"), and both the dropdown
        # and the filter collapse it to the primary subtag — so it has to be
        # collapsed here too, or every option looks dead.
        {:ok, offered} = Explorer.distinct_by_count("http_language", 300)

        counts =
          value_counts("""
          SELECT splitByChar('-', lower(http_language))[1] AS v, count()
          FROM domains_current WHERE http_language != '' GROUP BY v
          """)

        assert_all_offered_values_match(:language, offered, counts)
      end)
    end

    test "every freshness window" do
      with_clickhouse(fn ->
        for window <- ["24h", "7d", "30d"] do
          assert {:ok, n} = Explorer.count(freshness: window)
          assert n > 0, "the #{window} freshness filter matches nothing"
        end
      end)
    end
  end

  describe "tech page statistics" do
    test "the aggregate returns four real numbers for a high-volume tech" do
      with_clickhouse(fn ->
        assert {:ok, [[total, avg_rt, responding, top_100k]]} =
                 Clickhouse.tech_stats("Google Analytics")

        # Each of these rendered as 0 — or as the 100-row listing cap — when the
        # query timed out and the controller substituted a fallback.
        assert is_integer(total) and total > 0
        assert is_number(avg_rt) and avg_rt > 0
        assert is_integer(responding)
        assert is_integer(top_100k)

        assert total > 100,
               "total of #{total} looks like the 100-row listing cap, not a real count"
      end)
    end

    test "the aggregate agrees with a plain count of the same predicate" do
      with_clickhouse(fn ->
        {:ok, [[total, _, _, _]]} = Clickhouse.tech_stats("Klaviyo")

        {:ok, [[direct]]} =
          Clickhouse.query_raw("""
          SELECT count() FROM domains_current
          WHERE http_tech LIKE '%Klaviyo%' AND http_title != ''
          -- same unquoting as tech_stats: JSON output stringifies UInt64
          SETTINGS output_format_json_quote_64bit_integers = 0
          """)

        # Rows arrive continuously, so allow a little drift rather than equality.
        assert_in_delta total, direct, max(direct * 0.01, 100)
      end)
    end

    test "the aggregate completes well inside its timeout" do
      with_clickhouse(fn ->
        # It used to share the 10s default and intermittently blew it, which is
        # what triggered the fabricated fallback in the first place.
        {elapsed_us, {:ok, _}} = :timer.tc(fn -> Clickhouse.tech_stats("Shopify") end)

        assert elapsed_us / 1_000 < 30_000,
               "tech_stats took #{round(elapsed_us / 1_000)}ms — at this rate it will time out again"
      end)
    end
  end
  describe "sitemap contract (2026-08-08: sitemap advertised 404s)" do
    test "every top-shopify-stores-using URL the sitemap emits has rows behind it" do
      # The sitemap listed /top/shopify-stores-using-<tech> for every known
      # tech; techs with zero Shopify users (Pendo...) rendered 404 for
      # Google. The rule: the sitemap may only emit what the page can serve.
      with_clickhouse(fn ->
        {:ok, rows} = LS.Clickhouse.shopify_tech_names()

        sample = rows |> Enum.take_every(max(div(length(rows), 20), 1)) |> Enum.take(20)

        for [tech | _] <- sample do
          {:ok, stores} = LS.Clickhouse.top_stores_using_tech(tech, 1)

          assert stores != [],
                 "sitemap offers /top/shopify-stores-using-#{tech} but the page query finds nothing"
        end
      end)
    end
  end

end
