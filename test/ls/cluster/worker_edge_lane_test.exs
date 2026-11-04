defmodule LS.Cluster.WorkerEdgeLaneTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-11-03, measured after the booking limiter shipped fleet-wide: the
  30-minute tier A tick reached every node as batches of 60 to 190
  Shopify stores started at once. The 2 s edge line booked 16 of them
  inside the 30 s horizon and refused the rest; refused twice in one
  wave, a store was recorded as rate_limited and shelved for its cadence,
  350 to 835 stores a wave, about 45% of the wave's Shopify stores, while
  the line sat idle between waves. The HTTP stage now runs shared-edge
  targets in a lane four wide per batch so they are served in turn.
  """

  alias LS.Cluster.WorkerAgent

  @shopify "23.227.38.65"
  @plain "203.0.113."

  defp items(n_edge, n_plain) do
    edge = for i <- 1..n_edge, do: {"store#{i}.com", @shopify}
    plain = for i <- 1..n_plain, do: {"site#{i}.com", @plain <> "#{i}"}
    Enum.shuffle(edge ++ plain)
  end

  test "candidates split by shared edge, order kept within each side" do
    list = items(3, 4)
    {edge, plain} = WorkerAgent.split_by_edge(list, &elem(&1, 1))
    assert length(edge) == 3 and Enum.all?(edge, &(elem(&1, 1) == @shopify))
    assert length(plain) == 4 and Enum.all?(plain, &String.starts_with?(elem(&1, 1), @plain))
    assert edge == Enum.filter(list, &(elem(&1, 1) == @shopify))
    assert {[], []} == WorkerAgent.split_by_edge([], &elem(&1, 1))
  end

  test "shared-edge targets run at most four at a time while the rest run wide" do
    counter = :counters.new(4, [:atomics])
    # 1: edge running, 2: edge peak, 3: plain running, 4: plain peak
    track = fn {d, ip} ->
      {run, peak} = if LS.HTTP.IPRateLimiter.shared_edge?(ip), do: {1, 2}, else: {3, 4}
      :counters.add(counter, run, 1)
      now = :counters.get(counter, run)
      if now > :counters.get(counter, peak), do: :counters.put(counter, peak, now)
      Process.sleep(40)
      :counters.sub(counter, run, 1)
      {d, {:fetched, ip}}
    end

    list = items(24, 30)
    until = System.monotonic_time(:millisecond) + 5_000
    {res, cut} = WorkerAgent.fetch_split(list, &elem(&1, 1), track, 50, 5_000, until)

    assert cut == 0
    assert map_size(res) == 54
    assert Enum.all?(list, fn {d, ip} -> res[d] == {:fetched, ip} end)
    assert :counters.get(counter, 2) <= 4, "the edge lane is four wide"
    assert :counters.get(counter, 4) > 4, "the rest of the batch is not held back by the edge lane"
  end

  test "the deadline cuts both lanes and keeps what finished" do
    slow = fn {d, ip} ->
      if String.starts_with?(d, "store"), do: Process.sleep(2_000)
      {d, {:fetched, ip}}
    end

    list = items(6, 3)
    until = System.monotonic_time(:millisecond) + 300
    {res, cut} = WorkerAgent.fetch_split(list, &elem(&1, 1), slow, 50, 5_000, until)
    assert Enum.all?(1..3, &Map.has_key?(res, "site#{&1}.com")), "the plain sites finished"
    # collect_until/3 checks the deadline as results arrive, so the first
    # four stores may land before the lane halts; the two the lane never
    # started are reported as not finished, as a deadline cut always is.
    assert cut >= 2, "the stores still waiting on the lane are reported as not finished"
    assert map_size(res) + cut == 9
  end

  test "the stage sends both phases through the split" do
    src = File.read!("lib/ls/cluster/worker_agent.ex")
    assert src =~ "@edge_concurrency 4"
    assert src =~ "fetch_split(cands, &elem(&1, 1), fetch, conc, bound, min(home_deadline, deadline))"
    assert src =~ "fetch_split(due, &elem(&1, 2), fn {d, r, ip} -> {d, LS.Pipeline.secondary(r, d, ip)} end, conc, remaining, deadline)"
  end
end
