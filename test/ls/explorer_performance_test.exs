defmodule LS.ExplorerPerformanceTest do
  @moduledoc """
  Performance contract for the /dashboard queries, against a real ClickHouse.

  Regression: selecting country=US plus revenue $1M-$10M read 4.5GB across all
  81M rows to return 25, took 5-8s idle, and blew the query timeout under load —
  the dashboard reported "Search unavailable" after 10s.

  Correctness tests cannot catch this: the query was right, it was just too
  expensive. So this asserts cost directly, on the SQL the app actually builds
  (`Explorer.list_sql/2` and `count_sql/1`, not a copy of it).

  Two budgets per query:

    * wall clock — what the user feels, but noisy;
    * bytes_read — a property of the query plan, not the hardware. This is the
      one that fails loudly if anyone reintroduces the single-phase shape, even
      on a machine fast enough to hide the latency.

  Self-skips with no ClickHouse, so `mix test` stays green on a laptop. Prefer the
  local harness — the concurrency test deliberately saturates whatever it points
  at, and the master only has three cores to give:

      bash .ch/start-local-ch.sh
      mix test test/ls/explorer_performance_test.exs

  Against production, run the budget tests but expect to disturb live traffic:

      ssh -N -L 8123:127.0.0.1:8123 ls@45.63.7.58 &
      mix test test/ls/explorer_performance_test.exs --exclude concurrency
  """
  use ExUnit.Case, async: false

  alias LS.Clickhouse
  alias LS.Explorer

  @moduletag :performance
  @moduletag timeout: 300_000

  # Timings come from ClickHouse's own `statistics.elapsed`, never the client
  # clock, so these budgets mean the same thing whether the suite runs on the
  # master or over an SSH tunnel from a laptop.
  #
  # Two tiers, because what a filter must read is a property of the filter:
  # `:narrow` filters touch only LowCardinality columns; `:scan` filters match
  # inside a big String column (http_tech, http_apps, domain) and cannot avoid
  # reading it. Budgets are set from measured production values with headroom,
  # and the old single-phase query (4.5-5.4GB) fails every page budget.
  # bytes_read is the hard gate — it is a property of the query plan, so it means
  # the same thing on any hardware and under any load. The old single-phase query
  # read 4.51GB (narrow filters) and 5.24GB (scan filters) and fails both budgets.
  # The millisecond ceilings are deliberately loose: the master is a shared 3-core
  # box also running the ingest pipeline, so timings move around. They exist to
  # catch an order-of-magnitude regression, not to police a few hundred ms.
  @budgets %{
    page: %{narrow: {8_000, 2.5}, scan: {8_000, 3.5}},
    count: %{narrow: {4_000, 0.5}, scan: {4_000, 2.0}}
  }

  # Filter combinations a user can actually produce from the dropdowns, including
  # the exact one that was reported broken.
  @scenarios [
    {"no filters", [], :narrow},
    {"country=US + revenue $1M-$10M", [country: "US", revenue: "$1M-$10M"], :narrow},
    {"country=US", [country: "US"], :narrow},
    {"revenue $1M-$10M", [revenue: "$1M-$10M"], :narrow},
    {"employees 11-50", [employees: "11-50"], :narrow},
    {"industry=Fintech", [industry: "Fintech"], :narrow},
    {"business_model=SaaS + employees 501-5000",
     [business_model: "SaaS", employees: "501-5000"], :narrow},
    {"language=en + revenue $100M-$1B", [language: "en", revenue: "$100M-$1B"], :narrow},
    {"freshness 7d", [freshness: "7d"], :narrow},
    {"tech=Klaviyo", [tech: "Klaviyo"], :scan},
    {"tech=Shopify + country=GB", [tech: "Shopify", country: "GB"], :scan},
    {"US + Shopify + 11-50 employees",
     [country: "US", tech: "Shopify", employees: "11-50"], :scan},
    {"domain search", [domain_search: "shop"], :scan}
  ]

  setup_all do
    unless clickhouse_up?() do
      IO.puts("\n[performance] skipped — no ClickHouse reachable on 127.0.0.1:8123")
    end

    :ok
  end

  defp clickhouse_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))
  defp with_clickhouse(body), do: if(clickhouse_up?(), do: body.(), else: :ok)

  defp assert_budget(label, sql, kind, tier) do
    assert {:ok, m} = Clickhouse.measure(sql, 60_000)
    {max_ms, max_gb} = @budgets[kind][tier]
    assert_within(label, m, max_ms, max_gb)
  end

  defp assert_within(label, m, max_ms, max_gb) do
    gb = m.bytes_read / 1_000_000_000

    assert gb <= max_gb,
           """
           #{label} read #{Float.round(gb, 2)}GB (budget #{max_gb}GB).
           Reading this much to return #{m.rows_returned} rows means the query is
           scanning wide columns across the whole match set — see Explorer.list_sql/2.
           """

    assert m.elapsed_ms <= max_ms,
           "#{label} took #{m.elapsed_ms}ms (budget #{max_ms}ms), reading #{Float.round(gb, 2)}GB"

    m
  end

  describe "page queries stay within budget" do
    for {label, filters, tier} <- @scenarios do
      test "list: #{label}" do
        with_clickhouse(fn ->
          sql = Explorer.list_sql(unquote(filters), per_page: 25, page: 1)
          m = assert_budget("list(#{unquote(label)})", sql, :page, unquote(tier))

          assert m.rows_returned <= 25,
                 "returned #{m.rows_returned} rows for a 25-row page — the outer LIMIT is not holding"
        end)
      end

      test "count: #{label}" do
        with_clickhouse(fn ->
          sql = Explorer.count_sql(unquote(filters))
          assert_budget("count(#{unquote(label)})", sql, :count, unquote(tier))
        end)
      end
    end
  end

  describe "deep pagination does not degrade" do
    test "page 20 costs about the same as page 1" do
      with_clickhouse(fn ->
        filters = [country: "US", revenue: "$1M-$10M"]

        first = assert_budget("page 1", Explorer.list_sql(filters, page: 1), :page, :narrow)
        deep = assert_budget("page 20", Explorer.list_sql(filters, page: 20), :page, :narrow)

        assert deep.bytes_read <= first.bytes_read * 1.5,
               "page 20 read #{deep.bytes_read} vs page 1's #{first.bytes_read}"
      end)
    end
  end

  describe "pagination is stable" do
    test "consecutive pages never repeat or skip a domain" do
      with_clickhouse(fn ->
        filters = [country: "US", revenue: "$1M-$10M"]

        pages =
          for page <- 1..4 do
            {:ok, rows} = Explorer.list(filters, per_page: 25, page: page)
            Enum.map(rows, & &1["domain"])
          end

        all = List.flatten(pages)

        # tranco_rank has enormous NULL ties; without a deterministic tiebreaker
        # in the ORDER BY, the same domain lands on two pages and others vanish.
        assert length(Enum.uniq(all)) == length(all),
               "a domain appeared on more than one page: #{inspect(all -- Enum.uniq(all))}"
      end)
    end

    test "the same query twice returns the same page" do
      with_clickhouse(fn ->
        filters = [country: "US", revenue: "$1M-$10M"]

        {:ok, a} = Explorer.list(filters, per_page: 25, page: 3)
        {:ok, b} = Explorer.list(filters, per_page: 25, page: 3)

        assert Enum.map(a, & &1["domain"]) == Enum.map(b, & &1["domain"])
      end)
    end
  end

  describe "under concurrent load" do
    # The master has 3 cores and domains_current has no index for these queries,
    # so N simultaneous distinct filters are N full scans competing for CPU. The
    # box saturates around 4 concurrent users and no app-side tuning changes that
    # (max_threads=1 measured 3x worse); the structural fix is a projection
    # ordered by tranco_rank, or more cores.
    #
    # So the gate is what actually broke in production: every query must RETURN.
    # "Search unavailable" was a timeout, not a slow render. Latency is reported
    # rather than asserted tightly, because on a shared box it is not a stable
    # number — the per-query bytes_read budgets above are the real regression net.
    @concurrent_users 5
    @concurrent_budget_ms 45_000

    @tag :concurrency
    test "#{@concurrent_users} simultaneous filter changes all return inside the timeout" do
      with_clickhouse(fn ->
        # One filter change fires a list and a count together, so this is 2N
        # concurrent queries.
        outcomes =
          @scenarios
          |> Enum.take(@concurrent_users)
          |> Enum.map(fn {label, filters, _tier} ->
            Task.async(fn ->
              list = Task.async(fn -> measure_page(filters) end)
              count = Task.async(fn -> Clickhouse.measure(Explorer.count_sql(filters), 60_000) end)
              {label, Task.await(list, 90_000), Task.await(count, 90_000)}
            end)
          end)
          |> Task.await_many(180_000)

        failures = Enum.reject(outcomes, fn {_, l, c} -> match?({:ok, _}, l) and match?({:ok, _}, c) end)

        assert failures == [],
               "these filters errored under concurrent load: " <>
                 inspect(Enum.map(failures, fn {l, a, b} -> {l, a, b} end))

        timings =
          outcomes
          |> Enum.map(fn {label, {:ok, l}, {:ok, c}} -> {label, l.elapsed_ms + c.elapsed_ms} end)
          |> Enum.sort_by(&elem(&1, 1), :desc)

        IO.puts("\n[performance] #{@concurrent_users} concurrent (ClickHouse-side ms): #{inspect(timings)}")

        {slowest, ms} = hd(timings)

        assert ms < @concurrent_budget_ms,
               "#{slowest} spent #{ms}ms in ClickHouse under #{@concurrent_users}-way load. " <>
                 "This is a cliff detector, not an SLO — blowing it means concurrency " <>
                 "collapsed, not that things got a bit slower."
      end)
    end
  end

  defp measure_page(filters) do
    Clickhouse.measure(Explorer.list_sql(filters, per_page: 25, page: 1), 60_000)
  end
end
