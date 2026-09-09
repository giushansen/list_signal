defmodule LS.TechIndexTest do
  use ExUnit.Case, async: true

  alias LS.Clickhouse
  alias LS.TechIndex

  @moduledoc """
  The public tech, top, compare and directory pages read `tech_index`
  (2026-09-09) instead of scanning domains_current with LIKE: 1,844 scans a
  day at 29.5s average, 54,000 CPU-seconds, and the shape of the 09-07
  "Search unavailable" storm. These pin the index build and the rule that
  page inputs are bound as parameters, never spliced into SQL.
  """

  test "the server's build and the migration's first fill are the same statement" do
    migration = File.read!("clickhouse/migrations/024_tech_index.sql")
    [_, fill] = String.split(migration, "INSERT INTO ls.tech_index")
    from_migration = "INSERT INTO tech_index" <> fill

    norm = fn sql -> sql |> String.replace(~r/--[^\n]*/, "") |> String.replace(~r/\s+/, " ") |> String.replace("ls.", "") |> String.trim() |> String.trim_trailing(";") end
    assert norm.(TechIndex.build_sql("tech_index")) == norm.(from_migration)
  end

  test "the build dedups the source, explodes exact tokens and is bounded server-side" do
    sql = TechIndex.build_sql()
    assert sql =~ "FROM domains_current FINAL"
    assert sql =~ "ARRAY JOIN splitByChar('|', http_tech) AS tech"
    assert sql =~ "http_title != ''"
    assert sql =~ "max_execution_time = 1700"
    assert sql =~ "max_memory_usage = 3000000000", "the master shares 16G with ClickHouse's 7G cap and the app's 9G"
  end

  test "an empty or aged index is stale; a fresh one is not" do
    assert TechIndex.stale?(:empty)
    assert TechIndex.stale?(8 * 3600)
    refute TechIndex.stale?(3 * 3600)
  end

  describe "query parameters" do
    test "values are URL-bound, so a name with quotes or semicolons cannot alter the SQL" do
      assert Clickhouse.params_qs(%{t: "Vue.js"}) == "&param_t=Vue.js"
      assert Clickhouse.params_qs(%{t: "O'Neil; DROP TABLE x"}) == "&param_t=O%27Neil%3B+DROP+TABLE+x"
      assert Clickhouse.params_qs(%{}) == ""
    end

    test "array parameters take ClickHouse's literal form with quotes and backslashes escaped" do
      assert Clickhouse.array_param(["Shopify", "Klaviyo"]) == "['Shopify','Klaviyo']"
      assert Clickhouse.array_param(["O'Neil", "back\\slash"]) == "['O\\'Neil','back\\\\slash']"
    end
  end

  test "no public tech query interpolates the technology name or reads domains_fast with LIKE" do
    tech_section = File.read!("lib/ls/clickhouse/tech.ex")
    refute tech_section =~ ~r/LIKE '%#\{/, "a LIKE over an interpolated name is the 09-07 storm"
    refute tech_section =~ "FROM domains_fast"
    assert tech_section =~ "{t:String}"
  end
end
