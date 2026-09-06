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

  2026-09-06: the owner's rule is "a business is fetched at most once every
  7 days". Two 3.5-day blooms only guaranteed 3.5; eight daily windows
  guarantee 7 (and release by day 8). A suppressed certificate sighting is
  still recorded so subdomains and issuers seen between crawls are not
  thrown away.
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
    :persistent_term.put(@pt_key, for(_ <- 1..8, do: Bloom.new(10_000, 0.01)))
  end

  # One daily rotation: a fresh window in front, the oldest dropped.
  defp rotate do
    blooms = :persistent_term.get(@pt_key)
    :persistent_term.put(@pt_key, [Bloom.new(10_000, 0.01) | Enum.take(blooms, 7)])
  end

  test "first sight passes, second sight within the window is suppressed" do
    fresh_blooms()

    refute CrawlDedup.seen_or_mark("dedup-test-one.example")
    assert CrawlDedup.seen_or_mark("dedup-test-one.example")
    assert CrawlDedup.seen_or_mark("dedup-test-one.example")
  end

  test "a domain crawled today is still suppressed after seven daily rotations" do
    fresh_blooms()
    refute CrawlDedup.seen_or_mark("seven-days.example")

    for _ <- 1..7, do: rotate()

    assert CrawlDedup.seen_or_mark("seven-days.example"),
           "seven rotations must not reopen the window; the rule is at most one fetch per 7 days"
  end

  test "after eight rotations the entry is gone, so the weekly recrawl tier passes" do
    fresh_blooms()
    refute CrawlDedup.seen_or_mark("eight-days.example")

    for _ <- 1..8, do: rotate()

    refute CrawlDedup.seen_or_mark("eight-days.example")
  end

  test "a suppressed sighting is bounded and marks nothing new" do
    # Re-seeing a domain must not write it into the newest window again, or
    # a frequently renewed cert would push its next crawl out forever.
    fresh_blooms()
    refute CrawlDedup.seen_or_mark("sliding.example")
    for _ <- 1..7, do: rotate()
    assert CrawlDedup.seen_or_mark("sliding.example")
    rotate()
    refute CrawlDedup.seen_or_mark("sliding.example"), "a suppressed sighting extended the window"
  end

  test "the recrawl scheduler bypasses the gate with force: true" do
    fresh_blooms()
    refute CrawlDedup.seen_or_mark("forced.example")
    assert CrawlDedup.seen_or_mark("forced.example")

    assert :ok = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "forced.example", source: :recrawl}, force: true)
    assert File.read!("lib/ls/recrawl/scheduler.ex") =~ "enqueue(data, force: true)"
  end

  describe "sightings survive the suppression" do
    test "a suppressed certificate sighting is buffered for ClickHouse" do
      if :ets.info(:ctl_sightings_buffer) == :undefined,
        do: :ets.new(:ctl_sightings_buffer, [:set, :public, :named_table])

      :ets.delete_all_objects(:ctl_sightings_buffer)
      fresh_blooms()

      data = %{ctl_domain: "sighted.example", ctl_tld: "example", ctl_issuer: "R3", ctl_subdomain_count: 2, ctl_subdomains: "www|shop"}
      assert :ok = LS.Cluster.WorkQueue.enqueue(data)
      assert :recently_crawled = LS.Cluster.WorkQueue.enqueue(data)

      assert [{_, row}] = :ets.tab2list(:ctl_sightings_buffer)
      assert row =~ "sighted.example\t"
      assert row =~ "\tR3\t2\twww|shop"
      :ets.delete_all_objects(:ctl_sightings_buffer)
    end

    test "hostile certificate strings cannot break the TabSeparated batch" do
      row = CrawlDedup.sighting_row("evil.example", %{ctl_issuer: "a\tb\nc\\d", ctl_subdomains: String.duplicate("x", 10_000), ctl_subdomain_count: -5})
      refute row =~ "\n"
      refute row =~ "\\"
      assert length(String.split(row, "\t")) == 6
      assert String.length(row) < 4_500
      assert row =~ "\t0\t", "a negative count is stored as 0, never as a negative in a UInt column"
    end

    test "the buffer is capped so a ClickHouse outage cannot grow the master" do
      if :ets.info(:ctl_sightings_buffer) == :undefined,
        do: :ets.new(:ctl_sightings_buffer, [:set, :public, :named_table])

      :ets.delete_all_objects(:ctl_sightings_buffer)
      for i <- 1..CrawlDedup.buffer_cap(), do: :ets.insert(:ctl_sightings_buffer, {i, "x"})
      CrawlDedup.record_sighting(%{ctl_domain: "overflow.example"})
      assert :ets.info(:ctl_sightings_buffer, :size) == CrawlDedup.buffer_cap()
      :ets.delete_all_objects(:ctl_sightings_buffer)
    end
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
