defmodule LSWeb.ExplorerFiltersTest do
  @moduledoc """
  The filter dropdowns must only ever offer values the data can actually contain.

  Regression: /dashboard offered revenue brackets "$10M-$50M" and "$50M-$100M"
  and headcount brackets "51-200" and "201-500". LS.Revenue.Estimator has only
  ever written "$10M-$100M" and "51-500", so four of the twelve options matched
  0 rows out of ~80M. Confirmed against production ClickHouse:

      estimated_revenue = '$10M-$50M'  -> 0
      estimated_revenue = '$10M-$100M' -> 75,663
      estimated_employees = '201-500'  -> 0
      estimated_employees = '51-500'   -> 97,382
  """
  use LSWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LS.Explorer
  alias LS.Revenue.Estimator

  describe "dropdown options match what the estimator writes" do
    test "revenue options are exactly the estimator's bracket labels, smallest first" do
      assert Estimator.revenue_labels() ==
               ["<$1M", "$1M-$10M", "$10M-$100M", "$100M-$1B", "$1B+"]
    end

    test "employee options are exactly the estimator's employee labels, smallest first" do
      assert Estimator.employee_labels() ==
               ["1-10", "11-50", "51-500", "501-5000", "5001+"]
    end

    test "the brackets that returned 0 rows in production are no longer offered" do
      dead_revenue = ["$10M-$50M", "$50M-$100M"]
      dead_employees = ["51-200", "201-500"]

      for label <- dead_revenue do
        refute label in Estimator.revenue_labels(),
               "#{label} is offered but LS.Revenue.Estimator never writes it"
      end

      for label <- dead_employees do
        refute label in Estimator.employee_labels(),
               "#{label} is offered but LS.Revenue.Estimator never writes it"
      end
    end

    test "every offered label is reachable from a real bracket" do
      for bracket <- Estimator.brackets() do
        assert Estimator.bracket_label(bracket) in Estimator.revenue_labels()
        assert Estimator.employee_label(bracket) in Estimator.employee_labels()
      end
    end

    test "no label is blank or duplicated" do
      for labels <- [Estimator.revenue_labels(), Estimator.employee_labels()] do
        assert Enum.uniq(labels) == labels
        refute "" in labels
      end
    end

  end

  # Since pipeline 3 (2026-08-18) the revenue/employees filters match the
  # value the reader SEES: `verified_*` when an authoritative source filled it,
  # else `estimated_*`. Filtering on the estimate alone would hide a company
  # whose 10-K moved it out of the estimated bracket.
  @rev Explorer.shown_revenue_sql()
  @emp Explorer.shown_employees_sql()

  describe "the SQL those options produce" do
    test "a revenue option becomes an equality on the shown revenue (verified else estimated)" do
      for label <- Estimator.revenue_labels() do
        sql = Explorer.where_sql(revenue: label)
        assert sql == "WHERE #{@rev} = '#{label}'"
      end
    end

    test "an employees option becomes an equality on the shown employees" do
      for label <- Estimator.employee_labels() do
        sql = Explorer.where_sql(employees: label)
        assert sql == "WHERE #{@emp} = '#{label}'"
      end
    end

    test "multi-select becomes an IN list" do
      sql = Explorer.where_sql(revenue: "<$1M,$1B+")
      assert sql == "WHERE #{@rev} IN ('<$1M','$1B+')"
    end

    test "empty filters produce no WHERE clause" do
      assert Explorer.where_sql(revenue: "", employees: "", tech: "") == ""
    end

    test "tech filters match case-insensitively anywhere in the pipe-joined column" do
      assert Explorer.where_sql(tech: "Klaviyo") ==
               "WHERE (positionCaseInsensitive(http_tech, 'Klaviyo') > 0)"
    end

    test "multiple filters are ANDed" do
      sql = Explorer.where_sql(revenue: "$1M-$10M", employees: "11-50")

      assert sql =~ "#{@rev} = '$1M-$10M'"
      assert sql =~ "#{@emp} = '11-50'"
      assert sql =~ " AND "
    end

    test "single quotes in a filter value cannot break out of the literal" do
      assert Explorer.where_sql(revenue: "' OR 1=1 --") ==
               "WHERE #{@rev} = " <> ~S|'\' OR 1=1 --'|
    end
  end

  describe "the dropdowns as actually rendered on /dashboard" do
    setup :register_and_log_in_user

    # phx-value-value carries the string that ends up in the SQL literal, so
    # this asserts on exactly what the user's click sends to the backend.
    defp offered_values(html, field) do
      ~r/phx-click="select_option" phx-value-field="#{field}" phx-value-value="([^"]*)"/
      |> Regex.scan(html, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&unescape/1)
    end

    defp unescape(value) do
      Enum.reduce(
        [{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&#39;", "'"}, {"&amp;", "&"}],
        value,
        fn {entity, char}, acc -> String.replace(acc, entity, char) end
      )
    end

    for {field, labels_fun} <- [{"revenue", :revenue_labels}, {"employees", :employee_labels}] do
      test "the #{field} dropdown offers exactly the estimator's labels", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/dashboard")

        html = render_click(view, "open_dropdown", %{"field" => unquote(field)})
        offered = offered_values(html, unquote(field))

        assert offered == apply(Estimator, unquote(labels_fun), []),
               "#{unquote(field)} dropdown offers #{inspect(offered)}"
      end

      test "every #{field} option compiles to a clause that can match rows", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/dashboard")

        html = render_click(view, "open_dropdown", %{"field" => unquote(field)})

        for value <- offered_values(html, unquote(field)) do
          filter = [{String.to_existing_atom(unquote(field)), value}]
          sql = Explorer.where_sql(filter)

          assert sql != "", "#{unquote(field)}=#{value} produced no WHERE clause"
          assert sql =~ value, "#{unquote(field)}=#{value} did not reach the SQL: #{sql}"
        end
      end
    end
  end

  describe "a failed query is not reported as zero results" do
    test "query_error/2 reports whichever query failed" do
      assert LSWeb.ExplorerLive.query_error({:error, "CH 500"}, {:ok, 5}) == "CH 500"
      assert LSWeb.ExplorerLive.query_error({:ok, []}, {:error, :closed}) == :closed
      assert LSWeb.ExplorerLive.query_error(:killed, :killed) == :timeout
    end

    test "the dashboard distinguishes a failure from an empty result set" do
      source = File.read!("lib/ls_web/live/explorer_live.ex")

      assert source =~ "Search unavailable"
      assert source =~ "this is not an empty result"
    end
  end
end
