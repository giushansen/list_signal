defmodule LS.Cluster.StrandedEnrichmentTest do
  use ExUnit.Case, async: false

  @moduledoc """
  2026-09-23: stranded enrichment batches were requeued straight into the
  bucket, past the refill SQL's 7-day exclusion (no biz_enrichment row) and
  past the 24h cooldown (a direct ETS insert), so the same heavy sites
  stranded batch after batch: 2,696 requeues a day, 77% of every refill's
  candidates already attempted in the last 24 hours, the HTTP lane refilled
  100 to 1,200 domains per five minutes instead of 3,500, and pipeline 2 ran
  at a third of its rate for two weeks. A stranded item is now written down
  as a `render_engine = 'stranded'` row and dropped.
  """

  setup do
    Application.put_env(:ls, :clickhouse_req_options, plug: {Req.Test, __MODULE__})
    on_exit(fn -> Application.delete_env(:ls, :clickhouse_req_options) end)
    :ok
  end

  test "a stranded batch leaves one stranded row per domain and nothing in the buckets" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      conn = Plug.Conn.fetch_query_params(conn)
      send(self(), {:insert, conn.query_params["query"], body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    for t <- [:enrichment_queue, :enrichment_queue_browser, :enrichment_inflight, :enrichment_attempted] do
      if :ets.info(t) == :undefined, do: :ets.new(t, [:set, :public, :named_table])
    end

    before_http = :ets.info(:enrichment_queue, :size)
    before_browser = :ets.info(:enrichment_queue_browser, :size)
    old = System.system_time(:millisecond) - 3_600_000

    :ets.insert(
      :enrichment_inflight,
      {:stranded_test_batch, [%{domain: "heavy.example", last_http_status: 200}, %{domain: "walled.example", last_http_status: 403}], old}
    )

    {:noreply, _} = LS.Cluster.EnrichmentQueue.handle_info(:check_inflight, %{})

    assert_received {:insert, query, body}
    assert query =~ "INSERT INTO biz_enrichment (domain, enriched_at, render_engine, pipeline_version)"
    assert body =~ "heavy.example\t"
    assert body =~ "\tstranded\t"
    assert body =~ "walled.example\t"
    assert :ets.lookup(:enrichment_inflight, :stranded_test_batch) == []
    assert :ets.info(:enrichment_queue, :size) == before_http, "a stranded item must not be requeued"
    assert :ets.info(:enrichment_queue_browser, :size) == before_browser
  end

  test "hostile domain strings cannot break the TabSeparated batch" do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:body, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert :ok = LS.Cluster.EnrichmentWriter.write_stranded(["a\tb\nc\\d.example", "", nil, String.duplicate("x", 300)])
    assert_received {:body, body}
    lines = String.split(body, "\n", trim: true)
    assert length(lines) == 2
    refute Enum.any?(lines, &(&1 =~ "\\"))
    assert Enum.all?(lines, &(length(String.split(&1, "\t")) == 4))
    assert String.length(hd(lines) |> String.split("\t") |> hd()) <= 253
  end

  test "the refill SQL excludes anything attempted in the last seven days, stranded rows included" do
    src = File.read!("lib/ls/clickhouse.ex")
    [fun | _] = src |> String.split("def businesses_needing_enrichment") |> Enum.at(1) |> String.split("\n  end\n")
    assert fun =~ "NOT IN (SELECT domain FROM biz_enrichment WHERE enriched_at >= now() - INTERVAL 7 DAY)"
  end
end
