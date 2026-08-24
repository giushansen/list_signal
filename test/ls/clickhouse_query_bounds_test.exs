defmodule LS.ClickhouseQueryBoundsTest do
  @moduledoc """
  2026-08-24 outage: a client timeout does not stop ClickHouse. The dashboard
  gave up after 20s while the abandoned SELECT kept scanning for 250s+; every
  retry queued another onto a saturated box until nothing completed and the
  page showed "Search unavailable" (load 65 on 4 cores, 57 concurrent queries).

  The guarantee these tests protect: EVERY read path hangs up together. The
  first fix bounded query_raw only, and 62 of 68 in-flight scans still carried
  no cap because the private query/1 built its own URL — so the pile-up simply
  moved to the path that was missed.
  """
  use ExUnit.Case, async: true

  @src File.read!("lib/ls/clickhouse.ex")

  test "every read URL cancels the query when the client hangs up" do
    read_urls =
      @src
      |> String.split("\n")
      |> Enum.filter(&(&1 =~ ~r/url = "#\{@ch_url\}.*default_format=JSONCompact/))

    assert length(read_urls) >= 2, "expected the query_raw and query/1 read paths"

    for url <- read_urls do
      assert url =~ "cancel_http_readonly_queries_on_client_close=1",
             "unbounded read path — an abandoned query here keeps burning CPU: #{String.trim(url)}"
    end
  end

  test "the user-facing Explorer paths also cap execution server-side" do
    explorer = File.read!("lib/ls/explorer.ex")

    # list, count and count_many are what a waiting user triggers.
    assert length(Regex.scan(~r/max_execution_time:/, explorer)) >= 3,
           "list/count/count_many must each bound the server, not just our own client timeout"
  end
end
