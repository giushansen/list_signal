defmodule LS.Cluster.KnownBusinessGateTest do
  @moduledoc """
  2026-10-26, first tick with per-outcome accounting: of the 4,500 oldest
  due tier A businesses, 2,442 were refused by a ring; of 4,634 due B/C,
  4,135. Not dead, not queued: parked. A certificate re-sighting of a known
  business went through the first-contact name gate on the worker (no mail
  setup, unlisted TLD), which marks the stable or dormant ring, and the
  scheduler's forced refresh respects those rings. Every renewal repeated
  it, so the businesses were never refreshed again (the oldest since June).

  A compiled business now sits in the known ring; a certificate item for it
  is tagged `known: true` at enqueue and the worker treats it as a refresh.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.{CrawlDedup, WorkQueue, WorkerAgent}
  alias LS.Reputation.Bloom

  @known_key {LS.Cluster.CrawlDedup, :known}

  setup do
    saved = :persistent_term.get(@known_key, nil)
    on_exit(fn -> if saved, do: :persistent_term.put(@known_key, saved), else: :persistent_term.erase(@known_key) end)
    :persistent_term.put(@known_key, %{blooms: for(_ <- 1..2, do: Bloom.new(10_000, 0.01)), rotated_at: System.system_time(:second)})
    :ok
  end

  test "a compiled business is known for 400 days and then forgotten" do
    refute CrawlDedup.known?("shop.example")
    assert CrawlDedup.mark_known(["shop.example", "", nil]) == 1
    assert CrawlDedup.known?("shop.example")

    ring = :persistent_term.get(@known_key)
    now = System.system_time(:second)
    one = CrawlDedup.rotate_ring(:known, ring, now + 200 * 86_400 + 1)
    assert Enum.any?(one.blooms, &Bloom.member?(&1, "shop.example")), "day 200: still known"
    two = CrawlDedup.rotate_ring(:known, ring, now + 400 * 86_400 + 1)
    refute Enum.any?(two.blooms, &Bloom.member?(&1, "shop.example")), "day 400: forgotten"
  end

  test "a certificate item for a known business is tagged; a new name and a refresh item are not touched" do
    CrawlDedup.mark_known(["shop.example"])
    assert WorkQueue.tag_known(%{ctl_domain: "shop.example", source: :ctl}, "shop.example") == %{ctl_domain: "shop.example", source: :ctl, known: true}
    assert WorkQueue.tag_known(%{ctl_domain: "new.example", source: :ctl}, "new.example") == %{ctl_domain: "new.example", source: :ctl}
    refresh = %{ctl_domain: "shop.example", source: :recrawl, tier: "a"}
    assert WorkQueue.tag_known(refresh, "shop.example") == refresh
    assert WorkQueue.tag_known(%{}, nil) == %{}
    assert WorkQueue.tag_known(%{ctl_domain: ""}, "") == %{ctl_domain: ""}
  end

  test "the worker treats a known item as a refresh: no first-contact gate" do
    items = [
      %{ctl_domain: "shop.example", source: :ctl, known: true},
      %{ctl_domain: "sched.example", source: :recrawl, tier: "a"},
      %{ctl_domain: "new.example", source: :ctl},
      %{domain: "legacy.example", known: true},
      %{known: true}
    ]

    assert WorkerAgent.refresh_set(items) == MapSet.new(["shop.example", "sched.example", "legacy.example"])
    # The gate itself: a refresh never sees the TLD or mail rule.
    assert :crawl = WorkerAgent.prefetch_verdict("shop.top", "", "", "203.0.113.5", "", true)
    assert {:skip, _} = WorkerAgent.prefetch_verdict("shop.top", "", "", "203.0.113.5", "", false)
  end

  test "a known item that no longer resolves is recorded like a scheduler refresh" do
    items = [%{ctl_domain: "gone.example", source: :ctl, known: true}, %{ctl_domain: "newgone.example", source: :ctl}]
    dns = %{"gone.example" => %{dns: %{a: []}}, "newgone.example" => %{dns: %{a: []}}}
    assert WorkerAgent.unresolved_refresh(items, dns, []) == ["gone.example"]
  end

  test "the backfill query covers every non-junk business in disjoint shards" do
    sql = LS.Crawl.Tiers.known_sql(3, 32)
    assert sql =~ "estimated_junk = ''"
    assert sql =~ "cityHash64(domain) % 32 = 3"
    refute sql =~ "estimated_business_model"
    assert_raise FunctionClauseError, fn -> LS.Crawl.Tiers.known_sql(32, 32) end
  end
end
