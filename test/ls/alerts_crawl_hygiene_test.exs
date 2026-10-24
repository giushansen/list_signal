defmodule LS.AlertsCrawlHygieneTest do
  @moduledoc """
  2026-10-24: for at least three weeks a quarter to a third of enrich_log
  rows were hollow and, on the day before this test, half were duplicate
  fetches of the same domain by two nodes. The scheduler had also
  crash-looped for two hours on 2026-10-23 with no alert. None of it was
  visible without a query. These alerts make each a page.
  """
  use ExUnit.Case, async: true

  alias LS.Alerts

  defp keys(alerts), do: alerts |> Enum.map(& &1.key) |> Enum.sort()

  # The judgement needs the whole snapshot; this one is healthy and silent.
  defp healthy do
    %{
      ingestion_3h: 600_000,
      per_worker: for(i <- 1..8, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 180_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}),
      known_workers: for(i <- 1..8, do: "worker_n#{i}@10.0.0.#{i}"),
      stale_seconds: 200,
      worker_health: %{"worker_n1@10.0.0.1" => %{quarantined: false, ratio: 0.98, dropped: 0}},
      queue: %{queue_pct: 40.0},
      node_resources: [{:"master@10.0.0.1", %{disk_used_pct: 60, disk_used_gb: 200, disk_total_gb: 361, mem_avail_mb: 8000}}],
      reputation_ages: %{tranco: 5, majestic: 6, blocklist: 3},
      backups: %{dir: "/home/ls/backups", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 20},
      verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
      poller: nil,
      ctl_diff: %{new: [], retired: []},
      unmonitored_nodes: [],
      watchdog_restarts: [],
      data_check: %{quality: [], quantity: [], speed: []}
    }
  end

  defp evaluate(extra), do: Alerts.evaluate(Map.merge(healthy(), extra))

  test "a healthy fleet fires nothing: one row per domain, no hollow rows" do
    a = evaluate(%{crawl_hygiene: %{rows: 40_000, domains: 39_500, hollow: 120}})
    refute "crawl_duplicates" in keys(a)
    refute "crawl_hollow" in keys(a)
  end

  test "duplicate fetches are critical: it is the abuse-report pattern" do
    a = evaluate(%{crawl_hygiene: %{rows: 40_000, domains: 20_000, hollow: 0}})
    [dup] = Enum.filter(a, &(&1.key == "crawl_duplicates"))
    assert dup.severity == :critical
    assert dup.line =~ "2.0x"
  end

  test "hollow rows are a warning once past the ceiling" do
    a = evaluate(%{crawl_hygiene: %{rows: 40_000, domains: 40_000, hollow: 4_000}})
    [h] = Enum.filter(a, &(&1.key == "crawl_hollow"))
    assert h.severity == :warning
    assert h.line =~ "10.0%"
    refute "crawl_duplicates" in keys(a)
  end

  test "the thresholds sit where the 2026-10-23 numbers would have fired and a healthy day would not" do
    assert Alerts.dup_ratio_ceiling() < 444_252 / 222_320
    assert Alerts.hollow_pct_ceiling() < 34.0
    assert Alerts.dup_ratio_ceiling() >= 1.05
    assert Alerts.hollow_pct_ceiling() >= 2.0
  end

  test "a thin sample stays quiet, so a quiet night or a fresh boot cannot page" do
    a = evaluate(%{crawl_hygiene: %{rows: 400, domains: 100, hollow: 300}})
    assert keys(a) == []
  end

  test "a missing or broken metric stays quiet rather than lying" do
    assert evaluate(%{crawl_hygiene: nil}) == []
    assert evaluate(%{crawl_hygiene: %{rows: "x", domains: 1, hollow: 0}}) == []
    assert evaluate(%{crawl_hygiene: %{rows: 10_000, domains: 0, hollow: 0}}) == []
  end

  test "a scheduler that has not completed a tick in two hours is critical, after the boot grace" do
    a = evaluate(%{recrawl: %{last_tick_age_s: 3 * 3_600, vm_uptime_s: 10 * 3_600}})
    [r] = Enum.filter(a, &(&1.key == "recrawl_silent"))
    assert r.severity == :critical
    assert r.line =~ "180 min"

    # Never completed a tick since boot (a crash loop restarts the process, not the VM)
    [r2] = evaluate(%{recrawl: %{last_tick_age_s: nil, vm_uptime_s: 3 * 3_600}})
    assert r2.key == "recrawl_silent"
    assert r2.line =~ "since boot"
  end

  test "a recent tick, or a VM younger than the silence window, is quiet" do
    assert evaluate(%{recrawl: %{last_tick_age_s: 20 * 60, vm_uptime_s: 10 * 3_600}}) == []
    assert evaluate(%{recrawl: %{last_tick_age_s: nil, vm_uptime_s: 30 * 60}}) == []
    assert evaluate(%{recrawl: nil}) == []
  end
end
