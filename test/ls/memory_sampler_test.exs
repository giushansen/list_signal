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
  """

  describe "in_watch_zone?/2" do
    test "below the watch ratio is quiet" do
      refute MemorySampler.in_watch_zone?(3_000, 10_000)
      refute MemorySampler.in_watch_zone?(3_999, 10_000)
    end

    test "at or above the watch ratio is worth a trail" do
      assert MemorySampler.in_watch_zone?(4_001, 10_000)
      assert MemorySampler.in_watch_zone?(9_000, 10_000)
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
