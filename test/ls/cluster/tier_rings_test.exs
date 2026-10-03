defmodule LS.Cluster.TierRingsTest do
  use ExUnit.Case, async: false

  alias LS.Cluster.CrawlDedup
  alias LS.Reputation.Bloom

  @moduledoc """
  2026-10-03: a known tier B or C business waits its refresh cadence (60 or
  120 days) before a certificate re-sighting can fetch it again. The
  scheduler's force bypasses the tier rings (it is the schedule), a recorded
  change bypasses them too (a moving business is back on 7 days), and the
  rings rotate out after 7 windows of 10 or 20 days.
  """

  @b_key {LS.Cluster.CrawlDedup, :tier_b}
  @c_key {LS.Cluster.CrawlDedup, :tier_c}
  @daily_key {LS.Cluster.CrawlDedup, :blooms}
  @hot_key {LS.Cluster.CrawlDedup, :hot}

  setup do
    saved = for k <- [@b_key, @c_key, @daily_key, @hot_key], do: {k, :persistent_term.get(k, nil)}

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: :persistent_term.put(k, v), else: :persistent_term.erase(k))
    end)

    now = System.system_time(:second)
    :persistent_term.put(@daily_key, for(_ <- 1..8, do: Bloom.new(10_000, 0.01)))
    :persistent_term.put(@b_key, %{blooms: for(_ <- 1..7, do: Bloom.new(10_000, 0.01)), rotated_at: now})
    :persistent_term.put(@c_key, %{blooms: for(_ <- 1..7, do: Bloom.new(10_000, 0.01)), rotated_at: now})
    :persistent_term.put(@hot_key, %{blooms: for(_ <- 1..4, do: Bloom.new(10_000, 0.01)), rotated_at: now})
    Application.put_env(:ls, :tier_rings, true)
    :ok
  end

  test "a tier B business is skipped on re-sighting, taken by the scheduler's force, and counted" do
    refute CrawlDedup.tiered?("slow.example")
    assert CrawlDedup.mark_tier_b(["slow.example", "", nil]) == 1
    assert CrawlDedup.tiered?("slow.example")

    before = LS.Cluster.WorkQueue.stats().total_deduped_tier
    assert :recently_crawled = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "slow.example", source: :ctl})
    assert LS.Cluster.WorkQueue.stats().total_deduped_tier == before + 1
    assert :ok = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "slow.example", source: :recrawl, tier: "b"}, force: true)
  end

  test "a tier C business behaves the same under its own ring" do
    CrawlDedup.mark_tier_c(["quiet.example"])
    assert CrawlDedup.tiered?("quiet.example")
    assert :recently_crawled = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "quiet.example", source: :ctl})
  end

  test "a change puts a tiered business back on the fast schedule" do
    CrawlDedup.mark_tier_c(["moving.example"])
    CrawlDedup.mark_hot(["moving.example"])
    assert :ok = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "moving.example", source: :ctl})
  end

  test "the flag turns the tier gate off without losing the marks" do
    CrawlDedup.mark_tier_b(["flagged.example"])
    Application.put_env(:ls, :tier_rings, false)
    refute CrawlDedup.tiered?("flagged.example")
    Application.put_env(:ls, :tier_rings, true)
    assert CrawlDedup.tiered?("flagged.example")
  end

  test "tier B releases after 60-70 days and tier C after 120-140" do
    now = System.system_time(:second)
    CrawlDedup.mark_tier_b(["b.example"])
    CrawlDedup.mark_tier_c(["c.example"])
    b = :persistent_term.get(@b_key)
    c = :persistent_term.get(@c_key)

    six = CrawlDedup.rotate_ring(:tier_b, b, now + 6 * 10 * 86_400)
    assert Enum.any?(six.blooms, &Bloom.member?(&1, "b.example")), "day 60: still held"
    seven = CrawlDedup.rotate_ring(:tier_b, b, now + 7 * 10 * 86_400)
    refute Enum.any?(seven.blooms, &Bloom.member?(&1, "b.example")), "day 70: released"

    six_c = CrawlDedup.rotate_ring(:tier_c, c, now + 6 * 20 * 86_400)
    assert Enum.any?(six_c.blooms, &Bloom.member?(&1, "c.example")), "day 120: still held"
    seven_c = CrawlDedup.rotate_ring(:tier_c, c, now + 7 * 20 * 86_400)
    refute Enum.any?(seven_c.blooms, &Bloom.member?(&1, "c.example")), "day 140: released"
  end

  test "the stats report both rings" do
    stats = CrawlDedup.stats()
    assert Map.has_key?(stats, :tier_b_windows)
    assert Map.has_key?(stats, :tier_c_marked_total)
  end
end
