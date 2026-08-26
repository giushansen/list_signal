defmodule LS.BizSignalTest do
  @moduledoc """
  biz_signal sells displacement: "who dropped Klaviyo last month" is the
  highest-intent technographic signal we hold. The invariants that keep it
  honest, each pinned here:

    * a failed or blind crawl emits NOTHING — "removed" must always mean
      "observed gone", never "could not look";
    * a domain's first crawl emits nothing — "added everything" is noise;
    * a retried compaction slice re-emitting identical signals dedups.

  Runs against the local ClickHouse harness; skips without it.
  """
  use ExUnit.Case, async: false

  alias LS.Clickhouse

  @moduletag :data_contract

  @d "biz-signal-test.internal"

  defp ch_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))
  defp q(sql), do: Clickhouse.query_raw(sql)

  defp clean do
    # mutations_sync: an async DELETE races the next test's reads when the
    # full suite has ClickHouse busy — flaked 2026-08-26 with rows from the
    # previous test still visible.
    for t <- ~w(businesses biz_signal domains_history biz_enrichment_log) do
      q("ALTER TABLE #{t} DELETE WHERE domain = '#{@d}' SETTINGS mutations_sync = 1")
    end
  end

  defp signals do
    {:ok, rows} = q("SELECT kind, value FROM biz_signal FINAL WHERE domain = '#{@d}' ORDER BY kind, value")
    rows
  end

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

      q("INSERT INTO businesses (domain, first_seen, as_of, http_tech, http_apps, job_count) VALUES ('#{@d}', now() - INTERVAL 30 DAY, now() - INTERVAL 30 DAY, 'Shopify|Klaviyo', 'ReCharge', 0)")
      q("INSERT INTO domains_history (domain, enriched_at, http_status, http_tech, http_apps) VALUES ('#{@d}', now(), 200, 'Shopify|Gorgias', 'ReCharge|Judge.me')")
      q("INSERT INTO biz_enrichment_log (domain, enriched_at, render_engine, job_count) VALUES ('#{@d}', now(), 'http', 5)")

      assert :ok = Clickhouse.record_signals(now - 300, now + 60)

      assert signals() == [
               ["app_added", "Judge.me"],
               ["started_hiring", "5"],
               ["tech_added", "Gorgias"],
               ["tech_removed", "Klaviyo"]
             ]
    end)
  end

  test "a failed crawl emits nothing — removed means observed gone" do
    with_ch(fn ->
      now = System.system_time(:second)

      q("INSERT INTO businesses (domain, first_seen, as_of, http_tech) VALUES ('#{@d}', now() - INTERVAL 30 DAY, now() - INTERVAL 30 DAY, 'Shopify|Klaviyo')")
      q("INSERT INTO domains_history (domain, enriched_at, http_status, http_tech) VALUES ('#{@d}', now(), 403, '')")

      assert :ok = Clickhouse.record_signals(now - 300, now + 60)
      assert signals() == []
    end)
  end

  test "a first-ever crawl emits nothing — everything-added is noise" do
    with_ch(fn ->
      now = System.system_time(:second)

      # No businesses row at all: the domain is new to us.
      q("INSERT INTO domains_history (domain, enriched_at, http_status, http_tech) VALUES ('#{@d}', now(), 200, 'Shopify|Klaviyo')")

      assert :ok = Clickhouse.record_signals(now - 300, now + 60)
      assert signals() == []
    end)
  end

  test "a retried slice dedups instead of duplicating" do
    with_ch(fn ->
      now = System.system_time(:second)

      q("INSERT INTO businesses (domain, first_seen, as_of, http_tech) VALUES ('#{@d}', now() - INTERVAL 30 DAY, now() - INTERVAL 30 DAY, 'Shopify')")
      q("INSERT INTO domains_history (domain, enriched_at, http_status, http_tech) VALUES ('#{@d}', now(), 200, 'Shopify|Gorgias')")

      assert :ok = Clickhouse.record_signals(now - 300, now + 60)
      assert :ok = Clickhouse.record_signals(now - 300, now + 60)

      {:ok, [[n]]} = q("SELECT count() FROM biz_signal FINAL WHERE domain = '#{@d}'")
      assert n in [1, "1"]
    end)
  end

  test "the history backfill finds the same change a live diff would" do
    with_ch(fn ->
      q("INSERT INTO businesses (domain, first_seen, as_of, http_tech) VALUES ('#{@d}', now() - INTERVAL 60 DAY, now(), 'Shopify|Gorgias')")
      q("INSERT INTO domains_history (domain, enriched_at, http_status, http_tech) VALUES ('#{@d}', now() - INTERVAL 40 DAY, 200, 'Shopify|Klaviyo')")
      q("INSERT INTO domains_history (domain, enriched_at, http_status, http_tech) VALUES ('#{@d}', now() - INTERVAL 10 DAY, 200, 'Shopify|Gorgias')")

      # Run ONLY the shard this domain hashes into, out of a large shard count.
      # Running 8 shards over a full local domains_history means a
      # production-scale window-function walk per shard — the test timed out
      # at 60s. Ask ClickHouse which shard owns the domain and do that one.
      total = 4096
      {:ok, [[shard]]} = q("SELECT cityHash64('#{@d}') % #{total}")
      shard = if is_binary(shard), do: String.to_integer(shard), else: shard

      assert {:ok, _} = Clickhouse.backfill_signals_shard(shard, total)

      kinds = signals() |> Enum.map(&hd/1) |> Enum.sort()
      assert "tech_added" in kinds
      assert "tech_removed" in kinds
    end)
  end
end
