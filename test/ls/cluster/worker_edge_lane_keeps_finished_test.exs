defmodule LS.Cluster.WorkerEdgeLaneKeepsFinishedTest do
  @moduledoc """
  2026-11-04, 19:30 UTC: with a batch capped at eight Shopify stores the
  fleet wrote 11 to 59 Shopify rows a quarter hour, against 250 to 360
  before the cap, while every batch ran to its 420 s deadline and cut 6
  to 26 candidates; the node's Shopify line sat idle (booked 0.6 s
  ahead on ny1). The edge lane is one wide, each store waits its turn on
  the node budget behind the plain fetches, and when the store in hand
  outran the stage deadline the lane task was shut down whole: every
  store it had already fetched was dropped with it and counted as cut
  (69 of 82 on a run batch at 17:14 UTC, 13 kept, all of them plain).
  The lane now hands each finished store to the batch as it completes,
  so the deadline cuts only what is not done.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkerAgent

  @edge_ip "23.227.38.65"
  @plain_ip "93.184.216.34"

  defp now_ms, do: System.monotonic_time(:millisecond)

  test "a store finished before the deadline is kept when the next store outruns it" do
    fast = {"fast-store.test", @edge_ip}
    slow = {"slow-store.test", @edge_ip}
    plain = {"plain-site.test", @plain_ip}

    fun = fn
      {"slow-store.test" = d, _ip} -> Process.sleep(5_000); {d, :late}
      {d, _ip} -> {d, :ok}
    end

    assert WorkerAgent.edge_width(3) == 1
    until = now_ms() + 600
    {res, cut} = WorkerAgent.fetch_split([fast, slow, plain], &elem(&1, 1), fun, 4, 10_000, until)

    assert res["plain-site.test"] == :ok
    assert res["fast-store.test"] == :ok, "the finished store was dropped with the lane"
    refute Map.has_key?(res, "slow-store.test")
    assert cut == 1
  end

  test "a lane that finishes before the deadline returns every store, nothing cut" do
    items = for i <- 1..3, do: {"store#{i}.test", @edge_ip}
    fun = fn {d, _ip} -> {d, :ok} end
    {res, cut} = WorkerAgent.fetch_split(items, &elem(&1, 1), fun, 4, 10_000, now_ms() + 5_000)
    assert map_size(res) == 3
    assert cut == 0
  end

  test "a store whose fetch raises is cut, the others are kept" do
    items = [{"ok1.test", @edge_ip}, {"boom.test", @edge_ip}, {"ok2.test", @edge_ip}]
    fun = fn
      {"boom.test", _} -> raise "hostile"
      {d, _ip} -> {d, :ok}
    end
    {res, cut} = WorkerAgent.fetch_split(items, &elem(&1, 1), fun, 4, 10_000, now_ms() + 5_000)
    assert Map.keys(res) |> Enum.sort() == ["ok1.test", "ok2.test"]
    assert cut == 1
  end

  test "the batch returns at the deadline even while a store is still in flight" do
    items = [{"hang.test", @edge_ip}]
    fun = fn {d, _ip} -> Process.sleep(30_000); {d, :late} end
    t0 = now_ms()
    {res, cut} = WorkerAgent.fetch_split(items, &elem(&1, 1), fun, 4, 60_000, t0 + 500)
    assert res == %{}
    assert cut == 1
    assert now_ms() - t0 < 5_000
  end
end
