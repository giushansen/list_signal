defmodule LS.Cluster.ShopifySightingsBeforeRefreshesTest do
  @moduledoc """
  2026-11-09: Shopify stores found by DNS from a certificate sighting
  expired in the queue while tier A store refreshes took every Shopify
  slot. At 01:00 UTC the queue held 35,698 refreshes (priority 0) and
  20,518 sighted stores (priority 1); 15,442 of the sighted stores had
  never been fetched once (DNS-only rows since July, seen 3.3 times
  each), and 300 to 430 items an hour expired at the 24 h TTL, all but
  one of the oldest a sighting. A refresh that expires is due again the
  next day; a sighting that expires waits for the store's next
  certificate renewal, about two months. Sighted stores now dequeue
  first; refreshes take the Shopify slots that are left.
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

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}.test"
  defp refresh(i), do: %{ctl_domain: uniq("r#{i}"), source: :recrawl, tier: "a", prev_simhash: 0, edge: true}
  # What a worker hands back when DNS put a sighting behind Shopify's edge and the lane was full.
  defp sighted(i), do: %{ctl_domain: uniq("s#{i}"), edge: true}
  defp plain(i), do: %{ctl_domain: uniq("p#{i}"), source: :ctl}

  defp names({:ok, _bid, items}), do: Enum.map(items, & &1.ctl_domain)
  defp kind(name), do: String.first(name)

  describe "priority" do
    test "a sighted store sorts before a tier A refresh, which sorts before the rest" do
      assert WorkQueue.priority(%{ctl_domain: "s.test", edge: true}) == -1
      assert WorkQueue.priority(%{ctl_domain: "s.test", source: :ctl, edge: true}) == -1
      assert WorkQueue.priority(%{ctl_domain: "r.test", source: :recrawl, tier: "a", edge: true}) == 0
      assert WorkQueue.priority(%{"source" => :recrawl, "tier" => "a", edge: true}) == 0
      # A tier B or C refresh behind the edge keeps its place: the scheduler brings it back.
      assert WorkQueue.priority(%{ctl_domain: "b.test", source: :recrawl, tier: "b", edge: true}) == 1
      assert WorkQueue.priority(%{"source" => :recrawl, "tier" => "c", edge: true}) == 1
    end

    test "only the literal edge: true moves a name up; hostile tags stay where they were" do
      for tag <- ["true", 1, :yes, nil, false, %{}, [true]] do
        assert WorkQueue.priority(%{ctl_domain: "x.test", edge: tag}) == 1
      end

      assert WorkQueue.priority(%{edge: true}) == -1
      assert WorkQueue.priority(%{}) == 1
    end
  end

  describe "dequeue" do
    test "a batch's Shopify slots go to sighted stores first, oldest first, then to refreshes" do
      refreshes = for i <- 1..10, do: refresh(i)
      for r <- refreshes, do: :ok = WorkQueue.enqueue(r, force: true)
      sightings = for i <- 1..5, do: sighted(i)
      :ok = WorkQueue.requeue(sightings, :tail)
      Process.sleep(20)

      got = names(GenServer.call(WorkQueue, {:dequeue, 20, 8}))
      assert length(got) == 8
      assert Enum.take(got, 5) == Enum.map(sightings, & &1.ctl_domain)
      assert Enum.drop(got, 5) == Enum.map(Enum.take(refreshes, 3), & &1.ctl_domain)
      assert WorkQueue.stats().queue_depth_edge_sightings == 0
      assert WorkQueue.stats().queue_depth_priority == 7
    end

    test "refreshes still get every Shopify slot when no sighting waits" do
      for i <- 1..10, do: :ok = WorkQueue.enqueue(refresh(i), force: true)
      got = names(GenServer.call(WorkQueue, {:dequeue, 20, 8}))
      assert length(got) == 8
      assert Enum.all?(got, &(kind(&1) == "r"))
    end

    test "sightings never take more than the batch's Shopify cap, and plain names still flow" do
      :ok = WorkQueue.requeue(for(i <- 1..30, do: sighted(i)), :tail)
      for i <- 1..10, do: :ok = WorkQueue.enqueue(plain(i))
      Process.sleep(20)

      got = names(GenServer.call(WorkQueue, {:dequeue, 20, 8}))
      assert Enum.count(got, &(kind(&1) == "s")) == 8
      assert Enum.count(got, &(kind(&1) == "p")) == 10
      assert WorkQueue.stats().queue_depth_edge_sightings == 22
    end
  end
end
