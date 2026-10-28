defmodule LS.ExplorerTwoPhaseTest do
  @moduledoc """
  2026-10-28: the explorer page as one statement made ClickHouse evaluate
  the ranking twice (once to rank, once to build the IN set for the FINAL
  read): 3.6 s for the default first page on the master against 1.5 s plus
  0.4 s when the page is ranked first and the wide row is then read by key.
  """
  use ExUnit.Case, async: true

  alias LS.Explorer

  test "the ranking returns domains only, deduplicated, on the narrow scan" do
    sql = Explorer.rank_sql(%{country: "US"}, per_page: 25, page: 3)
    assert sql =~ "SELECT domain FROM ("
    assert sql =~ "estimated_country IN ('US')" or sql =~ "estimated_country = 'US'"
    assert sql =~ "LIMIT 1 BY domain"
    assert sql =~ ~r/LIMIT 25\s+OFFSET 50/
    refute sql =~ "FINAL", "FINAL belongs to the keyed read, never to the scan"
    refute sql =~ "http_title,", "the ranking must not read the wide columns"
  end

  test "the keyed read uses FINAL on a literal, escaped domain list and keeps the page order" do
    sql = Explorer.rows_sql(["acme.com", "o'reilly.com"], %{}, per_page: 25)
    assert sql =~ "FROM businesses FINAL"
    assert sql =~ "WHERE domain IN ('acme.com', 'o\\'reilly.com')"
    assert sql =~ "ORDER BY"
    assert sql =~ "LIMIT 25"
    refute sql =~ "SELECT domain FROM (", "the ranking must not run a second time"
  end

  test "only the unfiltered first page in the default order is the cached default view" do
    assert Explorer.default_view?(%{}, per_page: 25, page: 1)
    assert Explorer.default_view?(%{country: ""}, per_page: 100)
    refute Explorer.default_view?(%{country: "US"}, page: 1)
    refute Explorer.default_view?(%{}, page: 2)
    refute Explorer.default_view?(%{}, sort: "tranco_rank")
  end

  test "the single-statement form still exists for the budget tests and agrees with the two phases" do
    one = Explorer.list_sql(%{tech: "Shopify"}, per_page: 25, page: 1)
    rank = Explorer.rank_sql(%{tech: "Shopify"}, per_page: 25, page: 1)
    assert one =~ "FROM businesses FINAL"
    assert String.contains?(one, String.trim(rank) |> String.split("\n") |> Enum.at(1) |> String.trim())
  end
end
