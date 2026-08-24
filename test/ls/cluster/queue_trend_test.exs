defmodule LS.Cluster.QueueTrendTest do
  use ExUnit.Case, async: true

  alias LS.Cluster.QueueTrend

  @moduledoc """
  Pins the staffing maths that replaced a hard-coded `@per_worker_per_min 500`.

  2026-08-24: the dashboard sized the fleet from ONE sample of a bursty source.
  Three consecutive prod readings were 38,613 / 3,348 / 7,803 domains per
  minute, so the same healthy cluster was told it needed 1 worker or 21
  depending on the second you looked. These tests exist so that never returns.
  """

  # Build oldest-first samples one minute apart.
  defp samples(specs) do
    specs
    |> Enum.with_index()
    |> Enum.map(fn {{depth, enqueued, completed}, i} ->
      %{ts: 1_000_000 + i * 60_000, depth: depth, max: 3_000_000, enqueued: enqueued, completed: completed}
    end)
  end

  describe "burstiness cannot move the staffing answer" do
    test "an 11x swing between samples does not change workers_needed (the 2026-08-24 flapping bug)" do
      # Same hour of arrivals (6,000/min over 10 min), delivered two ways.
      steady = samples(for i <- 0..10, do: {50_000, i * 6_000, i * 6_000})

      bursty =
        samples(
          for i <- 0..10 do
            # All 60,000 arrive in two spikes; the counter total is identical.
            enq = if i < 5, do: i * 500, else: 2_500 + (i - 5) * 11_500
            {50_000, enq, i * 6_000}
          end
        )

      a = QueueTrend.analyze(steady, 8)
      b = QueueTrend.analyze(bursty, 8)

      assert a.demand_per_min == b.demand_per_min
      assert a.workers_needed == b.workers_needed
    end
  end

  describe "capacity is measured, never assumed" do
    test "capacity is unknown while the queue is shallow, and workers_needed stays nil rather than guessing" do
      # Depth below the saturation floor: workers may have been starved, so a
      # drain reading here is a floor on capacity, not a measurement of it.
      shallow = samples(for i <- 0..5, do: {100, i * 1_000, i * 1_000})
      t = QueueTrend.analyze(shallow, 8)

      assert t.capacity_per_min == nil
      assert t.workers_needed == nil, "must not invent a number from an idle fleet"
      assert t.surplus == nil
    end

    test "capacity is the BEST drain seen while saturated, not the average" do
      # Deep queue throughout. Drain per minute: 1k, 1k, 12k, 1k.
      s = samples([
        {50_000, 0, 0},
        {50_000, 1_000, 1_000},
        {50_000, 2_000, 2_000},
        {50_000, 3_000, 14_000},
        {50_000, 4_000, 15_000}
      ])

      t = QueueTrend.analyze(s, 8)
      assert t.capacity_per_min == 12_000, "an idle-ish minute must not hide proven capacity"
      assert t.per_worker_per_min == 1_500
    end

    test "an idle fleet is never reported short-staffed just because it drained slowly" do
      # Low demand, low drain, shallow queue — the exact shape that made the old
      # code scream "need 21 workers" while the queue sat empty.
      s = samples(for i <- 0..30, do: {0, i * 100, i * 100})
      t = QueueTrend.analyze(s, 8)

      refute t.workers_needed && t.workers_needed > t.workers
    end
  end

  describe "the queue is a buffer" do
    test "a growing backlog reports a finite runway to full" do
      # +1,000/min into a 3M cap; depth has reached 110k => 2,890 minutes left.
      s = samples(for i <- 0..10, do: {100_000 + i * 1_000, i * 10_000, i * 9_000})
      t = QueueTrend.analyze(s, 8)

      assert t.depth_slope_per_min == 1_000
      assert t.runway_minutes == 2_890
    end

    test "a shrinking backlog has no runway — the buffer is not filling" do
      s = samples(for i <- 0..10, do: {100_000 - i * 1_000, i * 9_000, i * 10_000})
      t = QueueTrend.analyze(s, 8)

      assert t.depth_slope_per_min == -1_000
      assert t.runway_minutes == :infinity
    end

    test "demand above capacity is short-staffed by the ratio, not by the backlog size" do
      # 12,000/min arriving, 8 workers proven at 1,500 each => needs 8. Add
      # 50% more demand and it needs 12.
      s = samples(for i <- 0..10, do: {50_000, i * 18_000, i * 12_000})
      t = QueueTrend.analyze(s, 8)

      assert t.per_worker_per_min == 1_500
      assert t.workers_needed == 12
      assert t.surplus == -4
    end
  end

  describe "hostile and empty input" do
    test "no samples, one sample, and sub-minute windows report insufficient_data instead of dividing by zero" do
      for s <- [[], samples([{1, 1, 1}])] do
        assert QueueTrend.analyze(s, 8).status == :insufficient_data
      end

      two_seconds_apart = [
        %{ts: 1_000, depth: 9, max: 10, enqueued: 0, completed: 0},
        %{ts: 3_000, depth: 9, max: 10, enqueued: 900, completed: 0}
      ]

      assert QueueTrend.analyze(two_seconds_apart, 8).status == :insufficient_data
    end

    test "zero workers never divides by zero" do
      s = samples(for i <- 0..5, do: {50_000, i * 1_000, i * 1_000})
      t = QueueTrend.analyze(s, 0)

      assert t.per_worker_per_min == nil
      assert t.workers_needed == nil
    end

    test "counters that went backwards (a queue restart) do not produce a negative fleet" do
      s = samples([{50_000, 900_000, 900_000}, {50_000, 10, 10}, {50_000, 20, 20}])
      t = QueueTrend.analyze(s, 8)

      assert is_nil(t.workers_needed) or t.workers_needed >= 1
    end

    test "a full queue reports no runway rather than a negative one" do
      s = samples([{3_000_000, 0, 0}, {3_000_000, 5_000, 0}, {3_000_000, 10_000, 0}])
      t = QueueTrend.analyze(s, 8)

      assert t.runway_minutes == :infinity
    end
  end
end
