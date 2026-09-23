defmodule LS.LandingCacheSlowTest do
  use ExUnit.Case, async: false

  @moduledoc """
  2026-09-23: the 30-minute cadence given on 09-10 to the landing page's
  slow counters and samples never cached anything: `cached/3` stores only
  `{:ok, _}` results, and these return plain values. query_log showed each
  of them still running 36 times an hour, about half a ClickHouse core for
  two weeks. `slow/2` wraps the value so it is cached and an error still is
  not.
  """

  setup do
    if :ets.info(:landing_cache) == :undefined,
      do: :ets.new(:landing_cache, [:named_table, :set, :public, read_concurrency: true])

    :ok
  end

  test "a plain value is computed once per window" do
    key = {:slow_test, System.unique_integer([:positive])}
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      [1, 2, 3]
    end

    assert LS.LandingCache.slow(key, fun) == [1, 2, 3]
    assert LS.LandingCache.slow(key, fun) == [1, 2, 3]
    assert :counters.get(counter, 1) == 1, "the second call must come from the cache"
  end

  test "an integer counter is cached too, and zero is a value, not a miss" do
    key = {:slow_test, System.unique_integer([:positive])}
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      0
    end

    assert LS.LandingCache.slow(key, fun) == 0
    assert LS.LandingCache.slow(key, fun) == 0
    assert :counters.get(counter, 1) == 1
  end
end
