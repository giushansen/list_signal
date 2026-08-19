defmodule LS.UICacheTest do
  @moduledoc """
  The cache exists to survive a launch spike, and it sits inside the BEAM heap
  that eight outages were traced to. So the two properties under test are the
  two that can take the site down:

    * single-flight — 25 concurrent misses on a cold key must run the work
      ONCE. A 2026-08-19 load test without it gave 1 req/s and 34% timeouts
      because every request recomputed the same seven 118M-row scans.
    * bounded memory — entries are capped and evicted, because an unbounded
      cache grows into the memory limit whose breach caused those outages.
  """
  use ExUnit.Case, async: false

  alias LS.UICache

  setup do
    for profile <- Map.keys(UICache.profiles()), do: UICache.invalidate(profile)
    :ok
  end

  describe "single-flight (the launch-critical property)" do
    test "concurrent misses on one key compute exactly once" do
      counter = :counters.new(1, [])
      key = {:test, System.unique_integer()}

      slow = fn ->
        :counters.add(counter, 1, 1)
        Process.sleep(150)
        :computed
      end

      results =
        1..25
        |> Task.async_stream(fn _ -> UICache.fetch(:tech_page, key, slow) end,
          max_concurrency: 25,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, v} -> v end)

      assert Enum.all?(results, &(&1 == :computed)),
             "every caller must receive the value, not just the winner"

      assert :counters.get(counter, 1) == 1,
             "expected 1 computation, got #{:counters.get(counter, 1)} — the stampede is back"
    end

    test "a crashing computation does not wedge later callers" do
      key = {:test, System.unique_integer()}

      # spawn_monitor, not Task.async: a linked task would take this test
      # process down with it and prove nothing about the cache.
      {pid, ref} = spawn_monitor(fn -> UICache.fetch(:tech_page, key, fn -> exit(:boom) end) end)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        5_000 -> flunk("the computing process never exited")
      end

      # The in-flight claim must not outlive the process that made it, or the
      # key is poisoned until restart and every later caller waits 10s.
      assert UICache.fetch(:tech_page, key, fn -> :recovered end) == :recovered
    end
  end

  describe "memory bounds (what keeps the box up)" do
    test "the entry cap is enforced by eviction" do
      max = UICache.stats().max_entries

      for i <- 1..(max + 600) do
        UICache.fetch(:tech_page, {:bound, i}, fn -> "v#{i}" end)
      end

      entries = UICache.stats().entries

      assert entries <= max,
             "cache holds #{entries} entries, above its own cap of #{max} — it can grow into the memory limit"
    end

    test "stats report per-profile counts so growth is attributable" do
      UICache.fetch(:dropdown, :tech, fn -> ["a"] end)
      UICache.fetch(:feed, :saas, fn -> [] end)

      stats = UICache.stats()
      assert stats.by_profile[:dropdown] >= 1
      assert stats.by_profile[:feed] >= 1
      assert is_integer(stats.bytes)
    end
  end

  describe "correctness" do
    test "errors are returned but never cached" do
      key = {:test, System.unique_integer()}
      assert UICache.fetch(:tech_page, key, fn -> {:error, :ch_down} end) == {:error, :ch_down}

      # A transient ClickHouse failure pinned for 6h would turn a blip into an
      # outage, so the next caller must retry rather than be served the error.
      assert UICache.fetch(:tech_page, key, fn -> :recovered end) == :recovered
    end

    test "every profile has a TTL matched to how fast its data really moves" do
      profiles = UICache.profiles()

      # Feeds are the freshness product: seconds, not hours.
      {feed_ttl, _} = profiles[:feed]
      assert feed_ttl <= 60, "the live feeds must not serve minutes-old data"

      # Page caches are 6h because a business is recrawled every ~8 days and a
      # tech aggregate moves under 2% in six hours (measured on prod).
      for p <- [:tech_page, :compare_page, :store_aggregate] do
        {ttl, _} = profiles[p]
        assert ttl >= 3_600, "#{p} recomputing more than hourly wastes the cache"
      end
    end

    test "an unknown profile is a compile-time-ish error, not a silent default" do
      assert_raise FunctionClauseError, fn ->
        UICache.fetch(:not_a_profile, :k, fn -> :v end)
      end
    end
  end
end
