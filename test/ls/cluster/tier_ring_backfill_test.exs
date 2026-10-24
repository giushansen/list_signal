defmodule LS.Cluster.TierRingBackfillTest do
  @moduledoc """
  2026-10-24: the tier C ring held 2.8M of 10.3M businesses because the
  compactor only marks what it compiles, and the rings (7 windows, 60-70
  and 120-140 days) were shorter than the 90/180-day cadences set on
  2026-10-23. About 56K known B and C businesses a day were fetched on a
  certificate renewal 14 to 70 days after their last visit. The rings are
  now 10 windows and a backfill places every existing business in the
  window its last check belongs to, so each releases on its own cadence.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.CrawlDedup
  alias LS.Reputation.Bloom

  @b_key {LS.Cluster.CrawlDedup, :tier_b}
  @c_key {LS.Cluster.CrawlDedup, :tier_c}
  @day 86_400

  setup do
    saved = for k <- [@b_key, @c_key], do: {k, :persistent_term.get(k, nil)}
    on_exit(fn -> for {k, v} <- saved, do: if(v, do: :persistent_term.put(k, v), else: :persistent_term.erase(k)) end)
    now = System.system_time(:second)
    :persistent_term.put(@b_key, %{blooms: for(_ <- 1..10, do: Bloom.new(10_000, 0.01)), rotated_at: now})
    :persistent_term.put(@c_key, %{blooms: for(_ <- 1..10, do: Bloom.new(10_000, 0.01)), rotated_at: now})
    {:ok, now: now}
  end

  test "a business checked after the rotation is in window 0, one period earlier per window, nil past the ring", %{now: now} do
    period = 10 * @day
    assert CrawlDedup.window_index(now, period, now + 5, 10) == 0
    assert CrawlDedup.window_index(now, period, now, 10) == 0
    assert CrawlDedup.window_index(now, period, now - 1, 10) == 1
    assert CrawlDedup.window_index(now, period, now - period, 10) == 2
    assert CrawlDedup.window_index(now, period, now - 8 * period - 1, 10) == 9
    assert CrawlDedup.window_index(now, period, now - 9 * period - 1, 10) == nil
  end

  test "window bounds tile the ring's span with no gap and no overlap", %{now: now} do
    period = 20 * @day
    assert CrawlDedup.window_bounds(now, period, 0) == {now, nil}
    assert CrawlDedup.window_bounds(now, period, 1) == {now - period, now}
    assert CrawlDedup.window_bounds(now, period, 9) == {now - 9 * period, now - 8 * period}

    for i <- 1..8 do
      {_, to} = CrawlDedup.window_bounds(now, period, i + 1)
      {from, _} = CrawlDedup.window_bounds(now, period, i)
      assert to == from
    end
  end

  test "marking into an older window releases that many periods sooner", %{now: now} do
    assert CrawlDedup.mark_into(:tier_b, 8, ["old.example", "", nil]) == 1
    assert CrawlDedup.mark_into(:tier_b, 0, ["fresh.example"]) == 1
    assert CrawlDedup.tiered?("old.example") and CrawlDedup.tiered?("fresh.example")

    b = :persistent_term.get(@b_key)
    two = CrawlDedup.rotate_ring(:tier_b, b, now + 2 * 10 * @day)
    refute Enum.any?(two.blooms, &Bloom.member?(&1, "old.example")), "window 8 is gone after two rotations"
    assert Enum.any?(two.blooms, &Bloom.member?(&1, "fresh.example"))
  end

  test "an index past the ring marks nothing rather than crashing" do
    assert CrawlDedup.mark_into(:tier_c, 10, ["x.example"]) == 0
    assert CrawlDedup.mark_into(:tier_c, 99, ["x.example"]) == 0
    refute CrawlDedup.tiered?("x.example")
  end

  test "a ring saved with 7 windows is restored into 10, entries kept, oldest windows empty", %{now: now} do
    blooms = for _ <- 1..7, do: Bloom.new(10_000, 0.01)
    Bloom.put(hd(blooms), "kept.example")
    bin = :erlang.term_to_binary(%{v: 1, rotated_at: now, blooms: Enum.map(blooms, &Bloom.to_binary/1)})

    {:ok, ring} = CrawlDedup.decode_ring(:tier_b, bin, now)
    assert length(ring.blooms) == 10
    assert Bloom.member?(hd(ring.blooms), "kept.example")
    assert Enum.drop(ring.blooms, 7) |> Enum.all?(&(Bloom.count(&1) == 0))

    # Corrupt and over-long payloads still start fresh.
    assert {:error, :corrupt} = CrawlDedup.decode_ring(:tier_b, :erlang.term_to_binary(%{v: 1, rotated_at: now, blooms: []}), now)
    eleven = for _ <- 1..11, do: Bloom.new(10, 0.1) |> Bloom.to_binary()
    assert {:error, :corrupt} = CrawlDedup.decode_ring(:tier_b, :erlang.term_to_binary(%{v: 1, rotated_at: now, blooms: eleven}), now)
  end

  test "the backfill query selects one tier, one last-check window, one hash shard, never junk" do
    sql = LS.Crawl.Tiers.backfill_sql("c", 1_700_000_000, 1_700_086_400, 2, 4)
    assert sql =~ "= 'c'"
    assert sql =~ "estimated_junk = ''"
    assert sql =~ "http_last_checked_at >= toDateTime(1700000000)"
    assert sql =~ "http_last_checked_at < toDateTime(1700086400)"
    assert sql =~ "cityHash64(domain) % 4 = 2"
    assert sql =~ "max_execution_time"

    open = LS.Crawl.Tiers.backfill_sql("b", 1_700_000_000, nil, 0, 4)
    refute open =~ "http_last_checked_at <"
    assert_raise FunctionClauseError, fn -> LS.Crawl.Tiers.backfill_sql("a", 0, nil, 0, 1) end
  end
end
