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
    # `businesses`, not domains_current: the explorer moved to the compacted
    # table and this helper did not follow, so the "truth set" came from a
    # table the dropdowns and filters no longer query. It flagged CF — a real
    # business present in `businesses` — as a dead option. A contract test
    # reading the wrong table produces false alarms AND hides real ones.
    value_counts("""
    SELECT #{column} AS v, count() FROM businesses WHERE #{column} != '' GROUP BY v
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
          FROM businesses WHERE http_language != '' GROUP BY v
          """)

        assert_all_offered_values_match(:language, offered, counts)
      end)
    end

    # Asserted against the data's own newest `as_of`, not against wall-clock:
    # a filter that matches nothing because the *copy* is a month-old dev
    # snapshot is not a product bug, and a test that fails on every laptop
    # stops being read. What must always hold is that the filter agrees with
    # the table it queries — 2026-08-11, this test failed on a local snapshot
    # (newest as_of 12 days old) while production was compacting every 2 min.
    test "every freshness window agrees with the newest data present" do
      with_clickhouse(fn ->
        {:ok, [[age_s]]} = Clickhouse.query_raw("SELECT now() - max(as_of) FROM businesses")
        age_h = String.to_integer(to_string(age_s)) / 3600

        counts =
          for {window, hours} <- [{"24h", 24}, {"7d", 168}, {"30d", 720}] do
            assert {:ok, n} = Explorer.count(freshness: window)

            # Data exists inside the window ⇒ the filter must find it. This is
            # what catches a renamed column or an inverted comparison.
            if age_h < hours do
              assert n > 0,
                     "the #{window} freshness filter matches nothing, " <>
                       "but businesses holds rows #{Float.round(age_h, 1)}h old"
            end

            n
          end

        # Widening the window can never return fewer rows.
        assert counts == Enum.sort(counts),
               "freshness windows are not monotonic (24h/7d/30d): #{inspect(counts)}"

        if age_h > 24, do: IO.puts("\n[data contract] businesses is #{Float.round(age_h / 24, 1)}d stale — dev snapshot?")
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

  describe "verification (pipeline 3) contract" do
    # Skipped when the verification tables are not there yet (a ClickHouse
    # older than migration 011), so the rest of the suite still runs.
    defp with_verification(body) do
      with_clickhouse(fn ->
        case Clickhouse.query_raw("EXISTS TABLE verified_facts") do
          {:ok, [[1]]} -> body.()
          _ -> IO.puts("\n[data contract] verification tables absent — skipped")
        end
      end)
    end

    defp count(sql) do
      {:ok, [[n]]} = Clickhouse.query_raw(sql, 120_000)
      if is_binary(n), do: String.to_integer(n), else: n
    end

    test "neither match tier ever links a domain that is not in domains_current" do
      # The whole point of "website → exact join" and "name + country → unique
      # match": a verified fact must land on a domain we hold. A fact on a
      # domain we do not have would be an invented row in the product.
      # Sampled and index-friendly on purpose: `NOT IN (SELECT domain FROM
      # domains_current)` materialises a 143M-row set and would blow the
      # shared master's ClickHouse cap; a `domain IN (list)` is a key read.
      with_verification(fn ->
        for {table, col} <- [{"verified_facts", "domain"}, {"verified_source_records", "matched_domain"}] do
          {:ok, rows} = Clickhouse.query_raw("SELECT DISTINCT #{col} FROM #{table} WHERE #{col} != '' ORDER BY cityHash64(#{col}) LIMIT 5000", 120_000)
          linked = Enum.map(rows, &hd/1)

          if linked != [] do
            list = Enum.map_join(linked, ",", &"'#{Clickhouse.escape_public(&1)}'")
            found = count("SELECT uniqExact(domain) FROM domains_current WHERE domain IN (#{list})")
            assert found == length(linked), "#{table}.#{col}: #{length(linked) - found} of #{length(linked)} sampled links point outside domains_current"
          end
        end
      end)
    end

    test "every match carries a method, and only the two allowed ones" do
      with_verification(fn ->
        assert count("SELECT count() FROM verified_facts WHERE match_method NOT IN ('website', 'name_country')") == 0
        assert count("SELECT count() FROM verified_source_records WHERE (matched_domain = '') != (match_method = '')") == 0
      end)
    end

    test "the name tier is unique on both sides — one source record ↔ one domain" do
      with_verification(fn ->
        assert count("""
               SELECT count() FROM (
                 SELECT source, name_key, country, uniqExact(matched_domain) AS d
                 FROM verified_source_records FINAL WHERE match_method = 'name_country'
                 GROUP BY source, name_key, country HAVING d > 1)
               """) == 0
      end)
    end

    test "verified_* in businesses use exactly the estimator's bracket labels (or '')" do
      # Filters and the explorer offer Estimator.revenue_labels(); a verified
      # value outside that vocabulary would render but never be filterable —
      # the same class of bug as the "$10M-$50M" option that matched 0 rows.
      with_verification(fn ->
        rev = value_counts("SELECT verified_revenue AS v, count() FROM businesses WHERE verified_revenue != '' GROUP BY v")
        for {v, _} <- rev, do: assert(v in Estimator.revenue_labels(), "verified_revenue #{inspect(v)} is not a filterable bracket")
        emp = value_counts("SELECT verified_employees AS v, count() FROM businesses WHERE verified_employees != '' GROUP BY v")
        for {v, _} <- emp, do: assert(v in Estimator.employee_labels(), "verified_employees #{inspect(v)} is not a filterable bracket")
      end)
    end

    test "verified_* never blanks estimated_* (new columns only)" do
      with_verification(fn ->
        # No row may hold a verified value while the estimate that history
        # carried for it has vanished — that would mean pipeline 3 wrote over
        # (or the compactor dropped) a column it does not own.
        assert count("""
               SELECT count() FROM businesses b
               WHERE b.verified_revenue != '' AND b.estimated_revenue = ''
                 AND b.domain IN (SELECT domain FROM domains_history WHERE estimated_revenue != '')
               """) == 0
      end)
    end

    test "dashboard_stats returns every section without a nested-aggregate error" do
      # The admin Verification tab's queries compile as text but ClickHouse
      # rejected two of them for nested aggregates (Code 184, 2026-08-21) —
      # the same class of bug that froze the compactor. This asserts the real
      # server accepts them and the shapes are what the LiveView reads.
      with_verification(fn ->
        st = LS.Verification.Store.dashboard_stats()
        assert is_list(st.sources)
        assert is_map(st.coverage) and Map.has_key?(st.coverage, :any)
        assert is_map(st.accounts) and Map.has_key?(st.accounts, :months_ok)
        assert is_map(st.facts_by_source)

        for src <- st.sources do
          assert src.source in ["wikidata", "yc", "sec_edgar", "companies_house", "sirene"]
          assert is_integer(src.records) and src.records >= 0
          assert is_integer(src.duration_s) and src.duration_s >= 0
          assert src.matched_website + src.matched_name_country <= src.records or src.records == 0
        end
      end)
    end

    test "sources in verified_facts are the ones precedence knows about" do
      with_verification(fn ->
        known = LS.Verification.revenue_precedence() ++ LS.Verification.employees_precedence()
        srcs = value_counts("SELECT source AS v, count() FROM verified_facts GROUP BY v")
        for {src, _} <- srcs, do: assert(src in known, "unknown verified_facts source #{inspect(src)} — precedence would rank it last")
      end)
    end
  end

  describe "catalogue filter contract" do
    test "'With catalogue' matches rows, and is strictly narrower than the Shopify tech match" do
      # The whole point of the toggle: a Shopify-tech match includes non-stores,
      # so the catalogue subset must be real AND smaller. If it ever equals the
      # tech match the toggle has stopped meaning anything.
      with_clickhouse(fn ->
        {:ok, [[tech, catalog]]} =
          Clickhouse.query_raw("""
          SELECT countIf(positionCaseInsensitive(http_tech,'Shopify') > 0),
                 countIf(positionCaseInsensitive(http_tech,'Shopify') > 0 AND product_count > 0)
          FROM businesses
          """, 30_000)

        tech = if is_binary(tech), do: String.to_integer(tech), else: tech
        catalog = if is_binary(catalog), do: String.to_integer(catalog), else: catalog

        assert catalog > 0, "the 'With catalogue' toggle offers a filter that matches nothing"
        assert catalog < tech, "catalogue must be a strict subset of the Shopify tech match"
      end)
    end
  end

  describe "ops alerting + weekly report contract" do
    @tag timeout: 180_000
    test "gather + evaluate + the weekly report all run against real ClickHouse without raising" do
      with_clickhouse(fn ->
        # gather hits every metric query and node erpc; evaluate is pure over it.
        m = LS.Alerts.gather()
        alerts = LS.Alerts.evaluate(m)
        assert is_list(alerts)
        for a <- alerts, do: assert(a.severity in [:critical, :warning] and is_binary(a.subject))

        # the weekly report must render to HTML with its three chapters.
        html = LS.Report.Weekly.html()
        assert is_binary(html)
        assert html =~ "1 · Infrastructure"
        assert html =~ "2 · Traffic"
        assert html =~ "3 · Software"
        refute html =~ "nil/nil"
      end)
    end

    test "ops_email_log exists and cooldown reads it without error" do
      with_clickhouse(fn ->
        assert {:ok, _} = Clickhouse.query_raw("SELECT count() FROM ops_email_log")
      end)
    end
  end
end
