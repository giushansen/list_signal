defmodule LS.Cluster.WorkQueuePriorityShareTest do
  @moduledoc """
  2026-10-27: two "Ingestion stalled" emails in six hours were right. With
  strict priority, the tier A lane (4,500 every 30 minutes, 150 a minute)
  took every slot of a fleet that does about 157 a minute since the
  address page joined the plan: new businesses went from 3,000 an hour to
  0 at 15:00 UTC on 10-26 and stayed there for nine hours while the queue
  grew to 251K. A batch is now at most 65% tier A while discovery waits.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue

  setup do
    case GenServer.whereis(WorkQueue) do
      nil ->
        {:ok, pid} = WorkQueue.start_link()
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      _ ->
        :ok
    end

    drain()
    :ok
  end

  defp drain do
    case GenServer.call(WorkQueue, {:dequeue, 10_000}) do
      {:ok, bid, _} ->
        GenServer.cast(WorkQueue, {:complete, bid, []})
        _ = WorkQueue.stats()
        drain()

      {:empty, []} ->
        :ok
    end
  end

  defp a(i), do: %{ctl_domain: "a#{i}-#{System.unique_integer([:positive])}.test", source: :recrawl, tier: "a", prev_simhash: 0}
  defp n(i), do: %{ctl_domain: "n#{i}-#{System.unique_integer([:positive])}.test", source: :ctl}
  defp kinds({:ok, _bid, items}), do: Enum.map(items, &if(&1[:source] == :recrawl, do: :a, else: :n))

  test "while discovery waits, tier A takes its share of a batch and discovery the rest, tier A first" do
    for i <- 1..20, do: :ok = WorkQueue.enqueue(a(i), force: true)
    for i <- 1..20, do: :ok = WorkQueue.enqueue(n(i))

    got = GenServer.call(WorkQueue, {:dequeue, 10})
    assert kinds(got) == [:a, :a, :a, :a, :a, :a, :a, :n, :n, :n]
    assert WorkQueue.priority_share() == 0.65
  end

  test "with no discovery waiting, tier A fills the whole batch" do
    for i <- 1..5, do: :ok = WorkQueue.enqueue(a(i), force: true)
    assert kinds(GenServer.call(WorkQueue, {:dequeue, 10})) == [:a, :a, :a, :a, :a]
  end

  test "with no tier A waiting, discovery fills the whole batch in order" do
    for i <- 1..4, do: :ok = WorkQueue.enqueue(n(i))
    {:ok, _, items} = GenServer.call(WorkQueue, {:dequeue, 10})
    assert Enum.map(items, &String.first(&1.ctl_domain)) == ~w(n n n n)
  end

  test "when discovery runs short, tier A fills what is left" do
    for i <- 1..20, do: :ok = WorkQueue.enqueue(a(i), force: true)
    for i <- 1..2, do: :ok = WorkQueue.enqueue(n(i))
    got = GenServer.call(WorkQueue, {:dequeue, 10})
    assert Enum.count(kinds(got), &(&1 == :n)) == 2
    assert length(kinds(got)) == 10
  end

  test "a batch of one still goes to tier A first" do
    :ok = WorkQueue.enqueue(n(1))
    :ok = WorkQueue.enqueue(a(1), force: true)
    assert kinds(GenServer.call(WorkQueue, {:dequeue, 1})) == [:a]
  end
end
