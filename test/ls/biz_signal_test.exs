defmodule LS.BizSignalTest do
  @moduledoc """
  changes_log sells displacement: "who dropped Klaviyo last month" is the
  highest-intent technographic signal we hold. The invariants that keep it
  honest, each pinned here against a real ClickHouse (data model v2,
  2026-10-01: detection compares the freshly compiled row with the current
  one inside the compaction pass):

    * a failed or blind crawl emits NOTHING: "removed" must always mean
      "observed gone", never "could not look";
    * a domain's first crawl emits nothing: "added everything" is noise;
    * a retried compaction slice re-emitting identical changes dedups;
    * hiring transitions come from the deep pass, as started / stopped.

  Runs against the local ClickHouse harness; skips without it.
  """
  use ExUnit.Case, async: false

  alias LS.Clickhouse

  @moduletag :data_contract

  @d "biz-signal-test.internal"
  @snippet String.duplicate("x", 300)

  defp ch_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))
  defp q(sql), do: Clickhouse.query_raw(sql)

  defp clean do
    for t <- ~w(businesses changes_log enrich_log http_deep_log) do
      q("ALTER TABLE #{t} DELETE WHERE domain = '#{@d}' SETTINGS mutations_sync = 1")
    end
  end

  defp changes do
    {:ok, rows} = q("SELECT field, change, value FROM changes_log FINAL WHERE domain = '#{@d}' ORDER BY field, change, value")
    rows
  end

  # A compiled v2 row as the pass would have left it 30 days ago.
  defp business!(tech, jobs \\ nil) do
    arr = tech |> Enum.map(&"'#{&1}'") |> Enum.join(",")
    jobs_sql = if jobs, do: "#{jobs}", else: "NULL"

    q("""
    INSERT INTO businesses (domain, ctl_first_seen_at, compiled_at, http_last_checked_at, http_last_seen_at, http_crawlable,
                            http_status, http_tech, estimated_business_model, estimated_business_model_confidence, hr_job_count, dns_a)
    VALUES ('#{@d}', now() - INTERVAL 30 DAY, now() - INTERVAL 30 DAY, now() - INTERVAL 30 DAY, now() - INTERVAL 30 DAY, 1,
            200, [#{arr}], 'Ecommerce', 0.9, #{jobs_sql}, ['1.2.3.4'])
    """)
  end

  defp crawl!(status, tech, opts \\ []) do
    at = Keyword.get(opts, :at, "now()")
    observed = Keyword.get(opts, :observed, 1)
    title = Keyword.get(opts, :title, "Acme store")

    q("""
    INSERT INTO enrich_log (domain, enriched_at, http_status, http_tech, http_title, http_body_snippet, http_observed, business_model, classification_confidence, dns_a)
    VALUES ('#{@d}', #{at}, #{status}, '#{tech}', '#{title}', '#{@snippet}', #{observed}, 'Ecommerce', 0.9, '1.2.3.4')
    """)
  end

  defp compact!(now), do: assert({:ok, _} = Clickhouse.compact_businesses(now - 300, now + 60))

  setup do
    if ch_up?() do
      clean()
      on_exit(fn -> clean() end)
      :ok
    else
      :ok
    end
  end

  defp with_ch(body), do: if(ch_up?(), do: body.(), else: :ok)

  test "a successful recrawl emits adds, removes, and hiring transitions" do
    with_ch(fn ->
      now = System.system_time(:second)
      business!(["Shopify", "Klaviyo"], 0)
      crawl!(200, "Shopify|Gorgias")
      q("INSERT INTO http_deep_log (domain, enriched_at, render_engine, job_count) VALUES ('#{@d}', now(), 'http', 5)")

      compact!(now)

      assert changes() == [
               ["hr_job_count", "started", "5"],
               ["http_tech", "added", "Gorgias"],
               ["http_tech", "removed", "Klaviyo"]
             ]
    end)
  end

  test "a failed crawl emits nothing: removed means observed gone" do
    with_ch(fn ->
      now = System.system_time(:second)
      business!(["Shopify", "Klaviyo"])
      crawl!(403, "", observed: 0)

      compact!(now)
      assert changes() == []
    end)
  end

  test "a first-ever crawl emits nothing: everything-added is noise" do
    with_ch(fn ->
      now = System.system_time(:second)
      # No businesses row at all: the domain is new to us.
      crawl!(200, "Shopify|Klaviyo")

      compact!(now)
      assert changes() == []
      {:ok, [[n]]} = q("SELECT count() FROM businesses WHERE domain = '#{@d}'")
      assert n in [1, "1"], "the first crawl still compiles the row"
    end)
  end

  test "a retried slice dedups instead of duplicating" do
    with_ch(fn ->
      now = System.system_time(:second)
      business!(["Shopify"])
      crawl!(200, "Shopify|Gorgias")

      compact!(now)
      compact!(now)

      {:ok, [[n]]} = q("SELECT count() FROM changes_log FINAL WHERE domain = '#{@d}'")
      assert n in [1, "1"]
    end)
  end

  test "an unknown handle never becomes a change: only catalog names are published" do
    with_ch(fn ->
      now = System.system_time(:second)
      business!(["Shopify"])
      crawl!(200, "Shopify|Notify Me Ninja Htn|Judgeme")

      compact!(now)
      # Judgeme is an alias of Judge.me; the handle is dropped.
      assert changes() == [["http_tech", "added", "Judge.me"]]
    end)
  end

  test "the history backfill finds the same change a live diff would" do
    with_ch(fn ->
      business!(["Shopify", "Gorgias"])
      crawl!(200, "Shopify|Klaviyo", at: "now() - INTERVAL 40 DAY")
      crawl!(200, "Shopify|Gorgias", at: "now() - INTERVAL 10 DAY")

      total = 4096
      {:ok, [[shard]]} = q("SELECT cityHash64('#{@d}') % #{total}")
      shard = if is_binary(shard), do: String.to_integer(shard), else: shard

      assert {:ok, _} = Clickhouse.backfill_changes_shard(shard, total)

      kinds = changes() |> Enum.map(&Enum.at(&1, 1)) |> Enum.sort()
      assert "added" in kinds
      assert "removed" in kinds
    end)
  end

  test "an unobserved crawl neither removes nor re-adds (2026-09-06)" do
    # 13.3% of "started showing" and 16.6% of "stopped showing" events in a
    # 3,000-event sample came from a stub crawl (bot wall served as 200,
    # redirect shell, empty body). A stub is "not observed", never "not
    # present": it must emit nothing, and the real crawl after it must not
    # emit fake re-adoptions of everything the stub lacked.
    with_ch(fn ->
      now = System.system_time(:second)
      business!(["Shopify", "Klaviyo"], 0)
      crawl!(200, "Cloudflare", observed: 0, title: "Just a moment...")

      compact!(now)
      assert changes() == [], "a bot wall served as 200 must not emit a removal"

      crawl!(200, "Shopify|Klaviyo", at: "now() + INTERVAL 1 SECOND")
      compact!(now)
      assert changes() == [], "the real crawl after a bot wall must not re-add what the wall hid"
    end)
  end
end
