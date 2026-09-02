defmodule LS.MemorySamplerTest do
  use ExUnit.Case, async: true

  alias LS.MemorySampler

  @moduledoc """
  2026-09-01: a real spike (3.3G -> 7.5G in under 8 minutes) crossed the
  gap between LS.Ops.MemoryForensics' 5-minute snapshots entirely -- the
  forensics existed and still could not say what grew. The watch zone below
  is the fix: a lower, edge-triggered logging threshold on the same 1s
  sampler that already feeds LSWeb.Plugs.OverloadGuard, so a future spike
  leaves a trail even before any request is actually shed.

  2026-09-02: the first version of that threshold (0.40) turned out to sit
  AT master's normal steady-state usage (3.7-4.3G of 9.2G, i.e. 40-47%), so
  it logged "entered watch zone" every few minutes around the clock instead
  of only for a real excursion. `above realistic steady-state baseline`
  below is the regression test for that: it would have failed against 0.40.
  """

  # Observed steady-state master readings, 2026-09-02 (bytes, 9.2G limit):
  # 3_770_000_000, 3_784_000_000, 4_298_000_000 was the noisiest sample seen.
  @observed_baseline_max_bytes 4_298_000_000
  @observed_limit_bytes 9_216_000_000

  describe "in_watch_zone?/2" do
    test "below the watch ratio is quiet" do
      refute MemorySampler.in_watch_zone?(3_000, 10_000)
      refute MemorySampler.in_watch_zone?(5_499, 10_000)
    end

    test "at or above the watch ratio is worth a trail" do
      assert MemorySampler.in_watch_zone?(5_501, 10_000)
      assert MemorySampler.in_watch_zone?(9_000, 10_000)
    end

    test "stays quiet at master's noisiest observed normal baseline, not just in the abstract" do
      refute MemorySampler.in_watch_zone?(@observed_baseline_max_bytes, @observed_limit_bytes),
             "the watch zone must sit above real steady-state noise, or every quiet night logs a false alarm"
    end

    test "sits below OverloadGuard's own shed ratio, so watch logging fires first" do
      # A spike should be visible in the logs before it ever costs a visitor
      # a 503 -- otherwise the first sign of trouble IS the outage.
      limit = 10_000
      shed_bytes = limit * LSWeb.Plugs.OverloadGuard.shed_ratio()

      assert MemorySampler.in_watch_zone?(round(shed_bytes) - 1, limit),
             "the watch zone must already be active by the time the shed ratio is reached"
    end

    test "a zero or negative limit never claims to be watching" do
      refute MemorySampler.in_watch_zone?(1_000, 0)
      refute MemorySampler.in_watch_zone?(1_000, -1)
    end
  end
end
