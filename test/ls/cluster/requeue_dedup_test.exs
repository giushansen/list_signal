defmodule LS.Cluster.RequeueDedupTest do
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue

  @moduledoc """
  A timed-out batch must never re-crawl domains that already completed.

  2026-08-28: Vultr forwarded an abuse report for morbihan-genealogie.bzh,
  visited by two of our IPs 31 minutes apart. The first node crawled it and
  its results were inserted; the batch still hit the 10-minute in-flight
  timeout (slow cycle, or the :complete cast lost to a master restart), so
  the master requeued all 1,000 domains and a second node crawled them again.
  29 such requeues in 48 hours meant ~29,000 domains double-crawled. The
  per-IP politeness limiter is per-node, so only the master can enforce
  politeness across the fleet, and it now does: requeues are filtered against
  the domains whose results actually arrived.
  """

  setup do
    if :ets.info(:recently_crawled) == :undefined do
      :ets.new(:recently_crawled, [:set, :public, :named_table, write_concurrency: true])
    end

    :ets.delete_all_objects(:recently_crawled)
    :ok
  end

  test "a completed domain is recognised for the TTL window" do
    WorkQueue.mark_recently_crawled([%{domain: "done.example", http_status: 200}])

    assert WorkQueue.recently_crawled?("done.example")
    refute WorkQueue.recently_crawled?("never-seen.example")
  end

  test "results carrying ctl_domain instead of domain are recognised too" do
    WorkQueue.mark_recently_crawled([%{ctl_domain: "ctl-shaped.example"}])
    assert WorkQueue.recently_crawled?("ctl-shaped.example")
  end

  test "an entry older than the TTL no longer blocks a legitimate recrawl" do
    :ets.insert(:recently_crawled, {"old.example", System.system_time(:millisecond) - :timer.hours(7)})
    refute WorkQueue.recently_crawled?("old.example")

    assert WorkQueue.sweep_recently_crawled() == 1
    assert :ets.lookup(:recently_crawled, "old.example") == []
  end

  test "hostile results never crash the completion path" do
    assert WorkQueue.mark_recently_crawled([
             %{},
             %{domain: nil},
             %{domain: ""},
             %{domain: 123},
             "not a map" |> then(fn _ -> %{domain: "ok.example"} end)
           ]) == :ok

    assert WorkQueue.mark_recently_crawled(:not_a_list) == :ok
    assert WorkQueue.recently_crawled?("ok.example")
    refute WorkQueue.recently_crawled?(nil)
  end

  test "the sweep bounds the table instead of letting it grow like the caches did" do
    now = System.system_time(:millisecond)

    for i <- 1..1_000 do
      :ets.insert(:recently_crawled, {"stale#{i}.example", now - :timer.hours(1)})
    end

    :ets.insert(:recently_crawled, {"fresh.example", now})

    assert WorkQueue.sweep_recently_crawled() == 1_000
    assert :ets.info(:recently_crawled, :size) == 1
  end

  test "the TTL matches what the requeue path actually needs, not hours (2026-08-29)" do
    # The table exists to answer ONE question: did this batch complete before
    # the 10-minute in-flight timeout fired. A row this stale can never be
    # consulted again, so keeping it costs memory for nothing. 6 hours of
    # retention grew this table to ~1.2M rows within 3 hours of a fresh boot
    # and was a real contributor to the 2026-08-28/29 memory-limit stalls —
    # the fix for one outage became a cause of the next.
    now = System.system_time(:millisecond)
    :ets.insert(:recently_crawled, {"just-over-batch-timeout.example", now - :timer.minutes(31)})

    refute WorkQueue.recently_crawled?("just-over-batch-timeout.example")
  end

  test "a burst that outruns the hourly sweep is capped, independent of the TTL" do
    now = System.system_time(:millisecond)

    for i <- 1..600_000 do
      :ets.insert(:recently_crawled, {"burst#{i}.example", now})
    end

    assert :ets.info(:recently_crawled, :size) == 600_000
    WorkQueue.sweep_recently_crawled()
    assert :ets.info(:recently_crawled, :size) <= 500_000
  end
end
