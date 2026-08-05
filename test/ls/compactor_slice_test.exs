defmodule LS.CompactorSliceTest do
  @moduledoc """
  2026-08-05: compaction died in a spiral — the catch-up window was "everything
  since the last success", so one timeout guaranteed every retry a bigger
  batch, and `businesses` went 19 hours stale while the raw data kept flowing.
  The rule that prevents it: a pass's window is BOUNDED, no matter how long
  the compactor has been failing.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.Compactor

  test "a pass's window never exceeds the slice, however far behind" do
    now = 1_800_000_000

    # 19 hours behind — the real incident. Window must still be one slice.
    since = now - 19 * 3600
    assert Compactor.slice_until(since, now) - since == 1_800

    # A week behind (post-incident cold start) — still one slice.
    assert Compactor.slice_until(now - 7 * 86_400, now) - (now - 7 * 86_400) == 1_800
  end

  test "a caught-up compactor stops at now, not in the future" do
    now = 1_800_000_000
    assert Compactor.slice_until(now - 60, now) == now
  end
end
