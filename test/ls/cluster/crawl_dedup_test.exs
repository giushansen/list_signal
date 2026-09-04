defmodule LS.Cluster.CrawlDedupTest do
  use ExUnit.Case, async: false

  alias LS.Cluster.CrawlDedup
  alias LS.Reputation.Bloom

  @moduledoc """
  The 7-day duplicate-crawl suppressor. Before it existed (2026-09-04),
  27.6% of all fetches were repeat visits inside one week (62.3M crawls,
  45.1M distinct domains): cert renewals re-emit from many CT logs and the
  CTL cache holds ~1 hour of inflow. Repeat visits from rotating worker
  IPs are also what turned two single-request crawls into Vultr abuse
  reports, so this is politeness infrastructure, not just capacity.
  """

  @pt_key {LS.Cluster.CrawlDedup, :blooms}

  # The real app-started blooms (standalone mode runs CrawlDedup for real)
  # must be restored, not clobbered: other tests enqueue domains.
  setup do
    saved = :persistent_term.get(@pt_key, nil)

    on_exit(fn ->
      case saved do
        nil -> :persistent_term.erase(@pt_key)
        blooms -> :persistent_term.put(@pt_key, blooms)
      end
    end)

    :ok
  end

  defp fresh_blooms do
    :persistent_term.put(@pt_key, {Bloom.new(10_000, 0.01), Bloom.new(10_000, 0.01)})
  end

  test "first sight passes, second sight within the window is suppressed" do
    fresh_blooms()

    refute CrawlDedup.seen_or_mark("dedup-test-one.example")
    assert CrawlDedup.seen_or_mark("dedup-test-one.example")
    assert CrawlDedup.seen_or_mark("dedup-test-one.example")
  end

  test "a domain in the PREVIOUS bloom is still suppressed after one rotation" do
    prev = Bloom.new(10_000, 0.01)
    Bloom.put(prev, "rotated-once.example")
    :persistent_term.put(@pt_key, {Bloom.new(10_000, 0.01), prev})

    assert CrawlDedup.seen_or_mark("rotated-once.example"),
           "one rotation must not reopen the window; suppression lasts 3.5-7 days"
  end

  test "after two rotations the entry is gone, so the weekly recrawl tier passes" do
    # An entry lives in current, then previous, then is dropped: gone by day
    # 7 at the latest. The weekly tier selects domains 7+ days stale, so a
    # recrawl must never be suppressed by its own previous visit.
    fresh_blooms()
    refute CrawlDedup.seen_or_mark("two-rotations.example")

    {current, _} = :persistent_term.get(@pt_key)
    :persistent_term.put(@pt_key, {Bloom.new(10_000, 0.01), current})
    {current2, _} = :persistent_term.get(@pt_key)
    :persistent_term.put(@pt_key, {Bloom.new(10_000, 0.01), current2})

    refute CrawlDedup.seen_or_mark("two-rotations.example")
  end

  test "fails OPEN with no blooms: a dedup outage must never stop discovery" do
    :persistent_term.erase(@pt_key)

    refute CrawlDedup.seen_or_mark("no-blooms-loaded.example")
    refute CrawlDedup.seen_or_mark("no-blooms-loaded.example")
  end

  test "hostile input is never seen rather than a crash" do
    fresh_blooms()

    refute CrawlDedup.seen_or_mark(nil)
    refute CrawlDedup.seen_or_mark("")
    refute CrawlDedup.seen_or_mark(12_345)
    refute CrawlDedup.seen_or_mark(%{})
  end

  test "the WorkQueue enqueue path consults the dedup and reports the suppression" do
    fresh_blooms()
    item = %{ctl_domain: "workqueue-dedup.example", source: :ctl}

    assert LS.Cluster.WorkQueue.enqueue(item) == :ok
    assert LS.Cluster.WorkQueue.enqueue(item) == :recently_crawled
    assert LS.Cluster.WorkQueue.stats().total_deduped >= 1
  end

  test "the requeue path bypasses enqueue/1, so a timed-out batch cannot be self-blocked" do
    # Items are marked in the bloom AT ENQUEUE. If requeue_timed_out went
    # back through enqueue/1, every timed-out batch would be suppressed by
    # its own entry and silently lost.
    src = File.read!("lib/ls/cluster/work_queue.ex")
    [requeue_body | _] = src |> String.split("defp requeue_timed_out") |> Enum.drop(1)
    [requeue_body | _] = String.split(requeue_body, "defp ")

    refute requeue_body =~ "enqueue(",
           "requeue must insert into ETS directly, never via enqueue/1"

    assert requeue_body =~ ":ets.insert(@queue_table"
  end
end
