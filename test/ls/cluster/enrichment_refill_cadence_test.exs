defmodule LS.Cluster.EnrichmentRefillCadenceTest do
  @moduledoc """
  2026-10-28: the depth queue refilled every 5 minutes with two full-table
  selections (35 s and 20 s on the master, 305 runs each in 30 h), 55 s of
  4-core ClickHouse time per 5 minutes to top up a queue h1 drains at about
  385 items per 5 minutes against a depth of 5,000. Every 20 minutes now.
  """
  use ExUnit.Case, async: true

  @drain_per_5_min 385
  @depth 5_000

  test "the cadence is 20 minutes" do
    assert LS.Cluster.EnrichmentQueue.refill_interval_ms() == :timer.minutes(20)
  end

  test "the queue still holds more than an hour of work after each refill at the measured drain" do
    per_interval = @drain_per_5_min * div(LS.Cluster.EnrichmentQueue.refill_interval_ms(), :timer.minutes(5))
    assert per_interval < @depth / 3, "a refill must not be needed before the next one"
  end

  test "the starved-lane alert still fires inside an hour" do
    streak = File.read!("lib/ls/alerts.ex") |> then(&Regex.run(~r/@lane_starved_streak (\d+)/, &1)) |> List.last() |> String.to_integer()
    assert streak * LS.Cluster.EnrichmentQueue.refill_interval_ms() <= :timer.hours(1)
  end
end
