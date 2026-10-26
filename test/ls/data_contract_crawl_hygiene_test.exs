defmodule LS.DataContractCrawlHygieneTest do
  @moduledoc """
  Crawl hygiene against a real ClickHouse (2026-10-24). Unit tests prove the
  queue heartbeats and the batch fits its budget; only the data can prove
  the fleet stopped fetching the same site twice and stopped writing rows
  with no fetch behind them. On 2026-10-23: 444,252 rows for 222,320
  domains, 150,530 hollow. Skipped when no ClickHouse is reachable, and
  when the sample is too thin to judge (a fresh harness).

      ssh -N -L 8123:127.0.0.1:8123 ls@45.63.7.58 &
      mix test test/ls/data_contract_crawl_hygiene_test.exs
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse
  alias LS.Metrics

  @moduletag :data_contract
  @min_rows 5_000

  defp clickhouse_up?, do: match?({:ok, _}, Clickhouse.query_raw("SELECT 1"))

  defp with_sample(hours, body) do
    if clickhouse_up?() do
      case Metrics.crawl_hygiene(hours) do
        %{rows: rows} = m when rows >= @min_rows -> body.(m)
        m -> IO.puts("\n[data contract] crawl hygiene skipped: thin sample #{inspect(m)}")
      end
    else
      :ok
    end
  end

  test "the fleet writes about one row per domain: no site is fetched twice by two nodes" do
    with_sample(6, fn %{rows: rows, domains: domains} ->
      ratio = rows / domains
      assert ratio <= LS.Alerts.dup_ratio_ceiling(),
             "#{rows} rows for #{domains} distinct domains in 6h (#{Float.round(ratio, 2)}x): duplicate fetches, check batch cycle time against WorkQueue.batch_timeout_ms"
    end)
  end

  test "a row has an HTTP outcome: status or error, never neither" do
    with_sample(6, fn %{rows: rows, hollow: hollow} ->
      pct = 100 * hollow / rows
      assert pct <= LS.Alerts.hollow_pct_ceiling(),
             "#{hollow} of #{rows} rows in 6h (#{Float.round(pct, 1)}%) have no HTTP status and no error: the HTTP stage is cutting candidates at its deadline"
    end)
  end

  test "the head of the due list churns: the oldest due tier A businesses were checked recently" do
    # 2026-10-26: the oldest 5,625 due tier A were last fetched in June, had
    # no row in 3 days, and were re-admitted every tick because the worker
    # dropped their failed DNS without a row. A check (fetch or
    # dns_unresolved) must move them off the head within a few ticks.
    if clickhouse_up?() do
      sql = """
      SELECT count(), countIf(domain IN (SELECT domain FROM enrich_log WHERE enriched_at >= now() - INTERVAL 3 DAY)) FROM (
        SELECT domain FROM (
          SELECT domain, #{LS.Crawl.Tiers.tier_sql()} AS tier, http_last_checked_at FROM businesses
          WHERE estimated_junk = '' AND http_error != 'robots_disallow' AND http_blocked = ''
            AND (http_status IS NULL OR http_status NOT IN (403, 503)) AND http_last_checked_at < now() - INTERVAL 14 DAY)
        WHERE tier = 'a' ORDER BY http_last_checked_at ASC, domain LIMIT 1000)
      SETTINGS max_threads = 2, max_memory_usage = 2000000000
      """

      case Clickhouse.query_raw(sql, 60_000) do
        {:ok, [[total, recent]]} when is_integer(total) and total >= 500 ->
          assert recent * 100 >= total * 70,
                 "#{total - recent} of the #{total} oldest due tier A businesses have no check in 3 days: the due list head is stuck, see LS.Cluster.WorkerAgent.unresolved_refresh/3"

        other ->
          IO.puts("\n[data contract] due-list head check skipped: #{inspect(other) |> String.slice(0, 120)}")
      end
    end
  end

  test "tier A businesses touched in a day were actually fetched, not just stamped" do
    if clickhouse_up?() do
      sql = """
      SELECT count(), countIf(fetched = 0) FROM (
        SELECT e.domain, countIf(NOT ((e.http_status IS NULL OR e.http_status = 0) AND e.http_error = '')) AS fetched
        FROM enrich_log e
        INNER JOIN (
          SELECT domain FROM businesses
          WHERE estimated_business_model IN ('Ecommerce','SaaS','Tool','Marketplace')
            AND (estimated_revenue NOT IN ('', '<$1M') OR coalesce(hr_job_count, 0) > 0 OR coalesce(shop_product_count, 0) > 0)
            AND domain IN (SELECT domain FROM enrich_log WHERE enriched_at >= now() - INTERVAL 6 HOUR)
        ) b ON b.domain = e.domain
        WHERE e.enriched_at >= now() - INTERVAL 6 HOUR
        GROUP BY e.domain)
      SETTINGS max_threads = 2, max_memory_usage = 2000000000
      """

      case Clickhouse.query_raw(sql, 60_000) do
        {:ok, [[total, only_hollow]]} when is_integer(total) and total >= 500 ->
          assert only_hollow * 100 <= total * 2,
                 "#{only_hollow} of #{total} tier A businesses touched in 6h got only hollow rows; their refresh was stamped, not done"

        other ->
          IO.puts("\n[data contract] tier A hollow check skipped: #{inspect(other) |> String.slice(0, 120)}")
      end
    end
  end
end
