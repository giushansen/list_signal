defmodule LSWeb.TechControllerTest do
  @moduledoc """
  /tech/:slug must never invent statistics.

  Regression: when the ClickHouse `tech_stats` aggregate timed out, the page fell
  back to `%{total: store_count, online_count: 0, top_100k_count: 0}` where
  `store_count` was the 100-row listing cap. /tech/google-analytics therefore
  advertised "100+ stores using Google Analytics", "0 Online" and "0 Top 100k
  sites" for a technology with ~1.5M matching rows.
  """
  use LSWeb.ConnCase, async: true

  setup do
    # /tech pages are public — no SQLite involved — but this module renders
    # them against a full local ClickHouse, and holding the sandbox's ONLY
    # connection through a multi-second render starves every queued test
    # setup. Same treatment as public_nav_test.
    Ecto.Adapters.SQL.Sandbox.checkin(LS.Repo)
    :ok
  end

  alias LSWeb.TechController

  describe "format_count/1" do
    test "groups thousands" do
      assert TechController.format_count(0) == "0"
      assert TechController.format_count(999) == "999"
      assert TechController.format_count(1_000) == "1,000"
      assert TechController.format_count(1_505_439) == "1,505,439"
      assert TechController.format_count(1_729.7) == "1,730"
    end

    test "returns nil for an unknown value rather than a stand-in number" do
      assert TechController.format_count(nil) == nil
      assert TechController.format_count("") == nil
    end
  end

  # These five tests assert what the page shows when EVERY aggregate errors —
  # the state production reached when tech_stats blew its 10s timeout. That
  # premise only holds when nothing answers on 127.0.0.1:8123; on a laptop
  # running the .ch/ dev harness a live ClickHouse turns the aggregates into
  # successes and the assertions become meaningless. Same conditional pattern
  # as LS.DataContractTest, just inverted. The deterministic core of this
  # regression stays covered unconditionally by "build_stats/1" and
  # "rendering with stores listed but stats unavailable" below.
  defp when_ch_down(body) do
    if match?({:error, _}, LS.Clickhouse.query_raw("SELECT 1")), do: body.(), else: :ok
  end

  describe "unavailable stats (ClickHouse down — exactly the timeout scenario)" do
    defp down_html(conn), do: conn |> get("/tech/google-analytics") |> response(200)

    test "does not claim a store count it could not measure", %{conn: conn} do
      when_ch_down(fn ->
        html = down_html(conn)
        refute html =~ ~r/\b100\+/
        refute html =~ "ListSignal tracks"
        refute html =~ ~r/\d+\+ Shopify stores use/
      end)
    end

    test "does not render placeholder zeros for the stat tiles", %{conn: conn} do
      when_ch_down(fn ->
        html = down_html(conn)
        refute html =~ "Returned HTTP 200"
        refute html =~ "Top 100K Sites"
      end)
    end

    test "never describes stores as 'currently online'", %{conn: conn} do
      when_ch_down(fn -> refute down_html(conn) =~ "currently online" end)
    end

    test "the page title carries no fabricated number", %{conn: conn} do
      when_ch_down(fn ->
        assert down_html(conn) =~ "<title>Google Analytics — Shopify Stores Using Google Analytics"
      end)
    end

    test "schema.org payload omits aggregateRating when the count is unknown", %{conn: conn} do
      when_ch_down(fn ->
        [json] =
          Regex.run(~r|<script type="application/ld\+json">(.*?)</script>|s, down_html(conn),
            capture: :all_but_first
          )

        decoded = Jason.decode!(json)

        assert decoded["name"] == "Google Analytics"
        refute Map.has_key?(decoded, "aggregateRating")
      end)
    end
  end

  describe "build_stats/1" do
    test "passes real measurements through" do
      assert TechController.build_stats({:ok, [[1_505_439, 1729.7, 1_500_847, 1061]]}) ==
               %{
                 total: 1_505_439,
                 avg_response_time: 1729.7,
                 responding_count: 1_500_847,
                 top_100k_count: 1061
               }
    end

    test "a failed aggregate yields nil everywhere, never 0 and never the row cap" do
      for failure <- [
            {:error, "CH 500: timeout"},
            {:error, :timeout},
            {:error, :unavailable},
            :killed,
            {:ok, []}
          ] do
        stats = TechController.build_stats(failure)

        assert stats == %{
                 total: nil,
                 avg_response_time: nil,
                 responding_count: nil,
                 top_100k_count: nil
               },
               "#{inspect(failure)} produced a fabricated stat: #{inspect(stats)}"
      end
    end
  end

  describe "rendering with stores listed but stats unavailable" do
    # The exact production shape: the 100-row listing succeeded, the aggregate
    # timed out. This is where the "100+ / 0 / 0" numbers used to come from.
    defp render_show(stats) do
      Phoenix.Template.render_to_string(LSWeb.TechHTML, "show", "html", %{
        conn: Phoenix.ConnTest.build_conn(),
        tech_name: "Google Analytics",
        slug: "google-analytics",
        stores: [],
        store_count: 100,
        stats: stats,
        countries: [],
        languages: [],
        hosting: [],
        registrars: [],
        co_techs: []
      })
    end

    test "renders no stat tiles and no store-count claim" do
      html = render_show(TechController.build_stats({:error, :timeout}))

      refute html =~ "100+"
      refute html =~ "Stores Using Google Analytics</div>"
      refute html =~ "Returned HTTP 200"
      refute html =~ "Top 100K Sites"
      refute html =~ "ListSignal tracks"
      refute html =~ "currently online"
    end

    test "renders exact, comma-grouped numbers when the aggregate succeeds" do
      html = render_show(TechController.build_stats({:ok, [[1_505_439, 1729.7, 1_500_847, 1061]]}))

      assert html =~ "1,505,439"
      assert html =~ "1,500,847"
      assert html =~ "1,061"
      assert html =~ "returned HTTP 200 the last time we crawled them"
      refute html =~ "1,505,439+"
      refute html =~ "currently online"
    end
  end

  describe "LandingCache.cached/3 (backs the tech_stats memoisation)" do
    test "computes once, then serves from ETS" do
      key = {:test_cached, System.unique_integer()}
      counter = :counters.new(1, [])

      run = fn ->
        LS.LandingCache.cached(key, :timer.minutes(5), fn ->
          :counters.add(counter, 1, 1)
          {:ok, :value}
        end)
      end

      assert run.() == {:ok, :value}
      assert run.() == {:ok, :value}
      assert :counters.get(counter, 1) == 1
    end

    test "never caches an error — a ClickHouse hiccup must not be pinned for the TTL" do
      key = {:test_cached, System.unique_integer()}

      assert LS.LandingCache.cached(key, :timer.minutes(5), fn -> {:error, :timeout} end) ==
               {:error, :timeout}

      assert LS.LandingCache.cached(key, :timer.minutes(5), fn -> {:ok, 42} end) == {:ok, 42}
    end
  end

  describe "the 'Online' metric" do
    test "no template describes HTTP-200-at-last-crawl as being online" do
      for file <- Path.wildcard("lib/ls_web/controllers/**/*.heex") do
        body = File.read!(file)
        refute body =~ "currently online", "#{file} claims to know whether a store is online"
        refute body =~ ~r/>\s*🟢 Online\s*</, "#{file} labels a crawl status as 'Online'"
      end
    end
  end
end
