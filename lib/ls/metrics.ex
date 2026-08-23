defmodule LS.Metrics do
  @moduledoc """
  Read-only snapshot of how ListSignal is doing — ingestion rates, per-worker
  throughput and quality, the product table's freshness and coverage, node
  resources, and the health of the master processes and downloads.

  One module so the admin dashboard, the alerter (`LS.Alerts`) and the weekly
  report (`LS.Report.Weekly`) all read the SAME numbers instead of each
  growing its own copy. Every function is read-only and returns plain maps/
  numbers; anything that talks to ClickHouse or another node degrades to a
  safe default rather than raising, because a metric failing must never take
  down the thing measuring it.

  Baselines that shaped the alert thresholds (measured 2026-08-23 on prod):
  fleet ingestion ~4-6.6M domains_history rows/day (~200k/hr) across 8 workers;
  ~700-950k rows per worker per 24h; ~23% of crawled rows get an HTTP peek and
  ~8.5% get classified; a worker's "resolved-but-HTTP-failed" rate sits at
  5-8% (it hit ~100% during the h1 split-brain incident — the signal to catch).
  """

  alias LS.Clickhouse

  # ── ClickHouse-backed ──

  @doc "domains_history rows inserted in the last `hours` (fleet ingestion volume)."
  def ingestion(hours \\ 3), do: ch_one("SELECT count() FROM domains_history WHERE enriched_at > now() - INTERVAL #{i(hours)} HOUR", 0)

  @doc "Per-worker throughput and quality over the last `hours`."
  def per_worker(hours \\ 6) do
    ch_rows("""
    SELECT worker,
      count() AS rows,
      round(100 * countIf(http_status BETWEEN 200 AND 399) / count(), 1) AS http_ok_pct,
      round(100 * countIf(dns_a != '' AND (http_status IS NULL OR http_status = 0) AND http_error != '') / nullif(countIf(dns_a != ''), 0), 1) AS resolved_fail_pct,
      round(100 * countIf(business_model != '') / count(), 1) AS classified_pct
    FROM domains_history WHERE enriched_at > now() - INTERVAL #{i(hours)} HOUR
    GROUP BY worker ORDER BY rows DESC
    """)
    |> Enum.map(fn [w, r, ok, rf, cl] ->
      %{worker: w, rows: to_i(r), http_ok_pct: to_f(ok), resolved_fail_pct: to_f(rf), classified_pct: to_f(cl)}
    end)
  end

  # A real fleet worker moves ~2M rows over 3 days; a transient/local debug
  # worker (e.g. worker_disc@127.0.0.1, 7.7k rows) does not. Require a floor so
  # a one-off node that came and went is never alerted as "down".
  @known_worker_floor 200_000

  @doc "Workers that did real work in the last `days` — the set we EXPECT to be live."
  def known_workers(days \\ 3) do
    ch_rows("SELECT worker, count() FROM domains_history WHERE enriched_at > now() - INTERVAL #{i(days)} DAY AND worker != '' GROUP BY worker HAVING count() >= #{@known_worker_floor}")
    |> Enum.map(&hd/1)
  end

  @doc "Row counts of the three end tables."
  def table_counts do
    case Clickhouse.query_raw("SELECT (SELECT count() FROM domains_current), (SELECT count() FROM domains_history), (SELECT count() FROM businesses FINAL)", 8_000) do
      {:ok, [[dc, dh, b]]} -> %{domains_current: to_i(dc), domains_history: to_i(dh), businesses: to_i(b)}
      _ -> %{domains_current: 0, domains_history: 0, businesses: 0}
    end
  end

  @doc "Seconds since the newest `businesses` row — how stale the product table is (compactor health)."
  def businesses_stale_seconds, do: ch_one("SELECT dateDiff('second', max(as_of), now()) FROM businesses", 0)

  @doc "Classification + junk coverage of the product table."
  def classification do
    case Clickhouse.query_raw("SELECT round(100*countIf(business_model!='')/count(),1), round(100*countIf(is_junk!='')/count(),1), count() FROM businesses FINAL", 8_000) do
      {:ok, [[c, j, n]]} -> %{classified_pct: to_f(c), junk_pct: to_f(j), total: to_i(n)}
      _ -> %{classified_pct: 0.0, junk_pct: 0.0, total: 0}
    end
  end

  @doc "Revenue/employee estimation + verification coverage."
  def estimation do
    case Clickhouse.query_raw("SELECT countIf(estimated_revenue!=''), countIf(verified_revenue!=''), countIf(verified_employees!='') FROM businesses FINAL", 8_000) do
      {:ok, [[e, vr, ve]]} -> %{estimated_revenue: to_i(e), verified_revenue: to_i(vr), verified_employees: to_i(ve)}
      _ -> %{estimated_revenue: 0, verified_revenue: 0, verified_employees: 0}
    end
  end

  @doc "Per-day domains_history volume for the last `days` (report trend + baseline)."
  def daily_ingestion(days \\ 8) do
    ch_rows("SELECT toDate(enriched_at) d, count() FROM domains_history WHERE enriched_at > now() - INTERVAL #{i(days)} DAY GROUP BY d ORDER BY d")
    |> Enum.map(fn [d, n] -> %{day: d, rows: to_i(n)} end)
  end

  @doc "Per-day pipeline-2 depth-enrichment volume."
  def daily_enrichment(days \\ 8) do
    ch_rows("SELECT toDate(enriched_at) d, count() FROM biz_enrichment WHERE enriched_at > now() - INTERVAL #{i(days)} DAY GROUP BY d ORDER BY d")
    |> Enum.map(fn [d, n] -> %{day: d, rows: to_i(n)} end)
  end

  @doc "Business-model distribution of the product table."
  def by_model do
    ch_rows("SELECT business_model, count() FROM businesses FINAL WHERE business_model!='' GROUP BY 1 ORDER BY 2 DESC")
    |> Enum.map(fn [m, n] -> %{model: m, count: to_i(n)} end)
  end

  @doc "Crawl-outcome breakdown over the last `hours` (HTTP ok / blocked / failed / no-peek)."
  def crawl_outcomes(hours \\ 24) do
    case Clickhouse.query_raw("""
         SELECT count() AS total,
           countIf(http_status BETWEEN 200 AND 399) AS ok,
           countIf(http_blocked != '') AS blocked,
           countIf(http_error != '') AS failed,
           countIf(dns_a = '' AND dns_cname = '') AS no_dns
         FROM domains_history WHERE enriched_at > now() - INTERVAL #{i(hours)} HOUR
         """, 15_000) do
      {:ok, [[t, ok, bl, f, nd]]} -> %{total: to_i(t), ok: to_i(ok), blocked: to_i(bl), failed: to_i(f), no_dns: to_i(nd)}
      _ -> %{total: 0, ok: 0, blocked: 0, failed: 0, no_dns: 0}
    end
  end

  @doc "Per-source verification volume + bytes downloaded (weekly report ch.2)."
  def verification_downloads do
    ch_rows("""
    SELECT source,
      argMax(records, started_at) AS records,
      argMax(matched_website + matched_name_country, started_at) AS matched,
      sum(bytes) AS bytes_total,
      max(started_at) AS last_run
    FROM verification_runs FINAL
    WHERE source IN ('wikidata','yc','sec_edgar','companies_house','sirene')
    GROUP BY source ORDER BY source
    """)
    |> Enum.map(fn [s, r, mt, b, lr] -> %{source: s, records: to_i(r), matched: to_i(mt), bytes: to_i(b), last_run: lr} end)
  end

  @doc "Real-business yield of the crawl: how many domains carry MX + a classified model (the sellable signal), last `days`."
  def real_business_yield(days \\ 7) do
    case Clickhouse.query_raw("SELECT sum(cnt) FROM daily_real_businesses WHERE day > today() - #{i(days)}", 8_000) do
      {:ok, [[v]]} -> to_i(v)
      _ -> 0
    end
  end

  # ── GenServer-backed (master processes) ──

  @doc "WorkQueue depth/fill, safe when not running."
  def queue, do: safe_stats(LS.Cluster.WorkQueue)

  @doc "Per-worker quarantine/health from the Inserter quality guard."
  def worker_health do
    try do
      LS.Cluster.Inserter.worker_health()
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  @doc "CT poller stats (per-log health), safe when the poller is not running (LS_MODE != ctl_live)."
  def poller do
    if Process.whereis(LS.CTL.Poller), do: safe(fn -> LS.CTL.Poller.stats() end, nil), else: nil
  end

  @doc "Verification pipeline summary (reuses the tab's stats)."
  def verification, do: safe(fn -> LS.Verification.dashboard_stats() end, nil)

  @doc "Age in hours of each reputation download (Tranco/Majestic/Blocklist); nil if the process is down."
  def reputation_ages do
    for {name, mod} <- [tranco: LS.Reputation.Tranco, majestic: LS.Reputation.Majestic, blocklist: LS.Reputation.Blocklist], into: %{} do
      age =
        case safe_stats(mod) do
          %{last_updated: %DateTime{} = t} -> DateTime.diff(DateTime.utc_now(), t, :hour)
          _ -> nil
        end

      {name, age}
    end
  end

  # ── Node resources (every node over erpc) ──

  @doc "Per-node CPU/RAM/disk/network, `[{node, map}]`. Unreachable nodes are dropped."
  def node_resources do
    [Node.self() | Node.list()]
    |> Enum.map(fn n -> {n, safe(fn -> :erpc.call(n, LS.Ops.NodeResources, :local, [], 3_000) end, nil)} end)
    |> Enum.reject(fn {_, r} -> is_nil(r) end)
  end

  # ── helpers ──

  defp ch_one(sql, default) do
    case Clickhouse.query_raw(sql, 15_000) do
      {:ok, [[v]]} -> to_i(v)
      _ -> default
    end
  end

  defp ch_rows(sql) do
    case Clickhouse.query_raw(sql, 20_000) do
      {:ok, rows} when is_list(rows) -> rows
      _ -> []
    end
  end

  defp safe_stats(mod), do: safe(fn -> GenServer.call(mod, :stats, 5_000) end, nil)

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  # Guard interpolated integers so no metric can inject SQL.
  defp i(n) when is_integer(n) and n > 0 and n < 100_000, do: n
  defp i(_), do: 1

  defp to_i(v) when is_integer(v), do: v
  defp to_i(v) when is_binary(v), do: (case Integer.parse(v) do
                                         {n, _} -> n
                                         :error -> 0
                                       end)
  defp to_i(_), do: 0

  defp to_f(v) when is_number(v), do: v * 1.0
  defp to_f(v) when is_binary(v), do: (case Float.parse(v) do
                                         {f, _} -> f
                                         :error -> 0.0
                                       end)
  defp to_f(_), do: 0.0
end
