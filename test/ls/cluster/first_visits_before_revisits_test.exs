defmodule LS.Cluster.FirstVisitsBeforeRevisitsTest do
  @moduledoc """
  2026-11-12, owner's rule: good business sites must be discovered and
  read first (priority #1), and refreshed after a while (priority #2);
  when #1 starts failing, refreshes wait and the less useful revisits are
  dropped.

  Measured 2026-11-11/12: of 38,295 Shopify stores fetched in a day, 5,464
  had been fetched under 29 days before. Those were certificate
  re-sightings of businesses we had compiled, queued at -1 with the
  stores never read once, while 16,061 never-read stores waited up to 15
  hours and 14,637 tier A refreshes waited behind them. On 11-07 and
  11-09 first visits expired at the 24 h TTL, 300 to 1,733 an hour, and
  nothing fired.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkQueue
  alias LS.Recrawl.Scheduler

  @hour 3_600_000

  setup do
    case GenServer.whereis(WorkQueue) do
      nil ->
        {:ok, pid} = WorkQueue.start_link()
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      _ ->
        :ok
    end

    drain()
    remeasure()

    on_exit(fn ->
      if GenServer.whereis(WorkQueue) do
        drain()
        remeasure()
      end
    end)

    :ok
  end

  defp drain do
    case GenServer.call(WorkQueue, {:dequeue, 10_000, 48}) do
      {:ok, bid, _} ->
        GenServer.cast(WorkQueue, {:complete, bid, []})
        _ = WorkQueue.stats()
        drain()

      {:empty, []} ->
        :ok
    end
  end

  # A sweep with nothing to expire resets the expiry count, then a stats
  # call waits for the queue to have handled it.
  defp remeasure do
    send(WorkQueue, :cleanup_ttl)
    _ = WorkQueue.stats()
    :ok
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}.test"
  defp names({:ok, _bid, items}), do: Enum.map(items, & &1.ctl_domain)

  # An item as if it had waited `age_ms`, put where enqueue/2 would.
  defp plant(data, age_ms) do
    key = WorkQueue.tail_key(data)
    :ets.insert(:work_queue, {key, data, System.system_time(:millisecond) - age_ms})
    :ets.insert(:work_queue_index, {data.ctl_domain, :queued})
    data
  end

  describe "who goes first" do
    test "a store we never read goes before a store we already know, whatever arrived first" do
      assert WorkQueue.priority(%{ctl_domain: "new.test", edge: true}) == -1
      assert WorkQueue.priority(%{ctl_domain: "old.test", edge: true, known: true}) == 1
      assert WorkQueue.priority(%{"known" => true, edge: true}) == 1
      # The never-fetched backlog waits behind refreshes so it cannot starve them.
      assert WorkQueue.priority(%{ctl_domain: "b.test", source: :backfill, edge: true}) == 1
      assert WorkQueue.priority(%{"source" => :backfill, edge: true}) == 1
      # A tier A refresh keeps 0, tagged known or not.
      assert WorkQueue.priority(%{ctl_domain: "r.test", source: :recrawl, tier: "a", edge: true, known: true}) == 0
    end

    test "only the literal known: true makes a sighting a revisit" do
      for tag <- ["true", 1, :yes, nil, false, %{}, [true]] do
        assert WorkQueue.first_visit?(%{ctl_domain: "x.test", known: tag})
        assert WorkQueue.priority(%{ctl_domain: "x.test", edge: true, known: tag}) == -1
      end

      refute WorkQueue.first_visit?(nil)
      refute WorkQueue.first_visit?("x.test")
      refute WorkQueue.first_visit?(%{source: :recrawl})
    end

    test "a batch's Shopify slots go to never-read stores, then refreshes, then known stores and the backlog" do
      known = for i <- 1..3, do: %{ctl_domain: uniq("k#{i}"), edge: true, known: true}
      backlog = for i <- 1..3, do: %{ctl_domain: uniq("b#{i}"), source: :backfill, edge: true}
      for item <- known ++ backlog, do: :ok = WorkQueue.enqueue(item)
      refresh = for i <- 1..2, do: %{ctl_domain: uniq("r#{i}"), source: :recrawl, tier: "a", edge: true}
      for r <- refresh, do: :ok = WorkQueue.enqueue(r, force: true)
      fresh = for i <- 1..2, do: %{ctl_domain: uniq("n#{i}"), edge: true}
      for f <- fresh, do: :ok = WorkQueue.enqueue(f)

      got = names(GenServer.call(WorkQueue, {:dequeue, 20, 5}))
      assert got == Enum.map(fresh ++ refresh, & &1.ctl_domain) ++ [hd(known).ctl_domain]
      assert WorkQueue.stats().queue_depth_backfill == 3
    end
  end

  describe "first-visit health" do
    test "thresholds: behind at 12 h, losing at 20 h or 100 expired in a sweep" do
      assert WorkQueue.lane_health(nil, 0) == :ok
      assert WorkQueue.lane_health(0, 0) == :ok
      assert WorkQueue.lane_health(12 * @hour - 1, 0) == :ok
      assert WorkQueue.lane_health(12 * @hour, 0) == :behind
      assert WorkQueue.lane_health(20 * @hour - 1, 99) == :behind
      assert WorkQueue.lane_health(20 * @hour, 0) == :losing
      assert WorkQueue.lane_health(nil, 100) == :losing
      assert WorkQueue.lane_health(0, 100) == :losing
    end

    test "only first visits count as lost when a sweep expires items" do
      items = [
        {{-1, 1}, %{ctl_domain: "a", edge: true}, 0},
        {{1, 2}, %{ctl_domain: "b", edge: true, known: true}, 0},
        {{1, 3}, %{ctl_domain: "c", source: :backfill, edge: true}, 0},
        {{0, 4}, %{ctl_domain: "d", source: :recrawl, tier: "a"}, 0},
        {{1, 5}, %{ctl_domain: "e", source: :ctl}, 0},
        {{1, 6}, %{ctl_domain: "f", known: true}, 0},
        :garbage,
        {{1, 7}, nil, 0}
      ]

      assert WorkQueue.expired_first_visits(items) == %{edge: 1, plain: 1}
      assert WorkQueue.expired_first_visits([]) == %{edge: 0, plain: 0}
    end

    test "a never-read store waiting 13 h puts the edge behind; the plain lane is judged on its own" do
      plant(%{ctl_domain: uniq("old"), edge: true}, 13 * @hour)
      plant(%{ctl_domain: uniq("plain"), source: :ctl}, 1 * @hour)
      # A known store waiting a day does not make the edge look behind.
      plant(%{ctl_domain: uniq("known"), edge: true, known: true}, 23 * @hour)
      send(WorkQueue, :measure_health)
      fv = WorkQueue.stats().first_visits

      assert fv.edge == :behind
      assert fv.edge_oldest_h >= 13.0 and fv.edge_oldest_h < 13.1
      assert fv.plain == :ok
      assert fv.plain_oldest_h >= 1.0 and fv.plain_oldest_h < 1.1
      assert WorkQueue.first_visit_health() == fv
    end

    test "100 never-read stores expired in one sweep is losing, and the next quiet sweep clears it" do
      for i <- 1..100, do: plant(%{ctl_domain: uniq("x#{i}"), edge: true}, 25 * @hour)
      send(WorkQueue, :cleanup_ttl)
      fv = WorkQueue.stats().first_visits
      assert fv.edge == :losing
      assert fv.edge_expired == 100
      assert fv.plain == :ok
      assert WorkQueue.stats().queue_depth == 0

      remeasure()
      assert WorkQueue.first_visit_health().edge == :ok
    end
  end

  describe "losing drops revisits on the plain lane only" do
    @known_key {LS.Cluster.CrawlDedup, :known}

    setup do
      saved = :persistent_term.get(@known_key, nil)
      on_exit(fn -> if saved, do: :persistent_term.put(@known_key, saved), else: :persistent_term.erase(@known_key) end)
      :persistent_term.put(@known_key, %{blooms: for(_ <- 1..2, do: LS.Reputation.Bloom.new(10_000, 0.01)), rotated_at: System.system_time(:second)})
      :ok
    end

    defp lose(item_fun) do
      for i <- 1..100, do: plant(item_fun.(i), 25 * @hour)
      send(WorkQueue, :cleanup_ttl)
      WorkQueue.stats().first_visits
    end

    test "plain first visits expiring: a re-sighting of a compiled business is recorded, not queued" do
      assert lose(&%{ctl_domain: uniq("p#{&1}"), source: :ctl}).plain == :losing
      known = uniq("known")
      LS.Cluster.CrawlDedup.mark_known([known])
      before = WorkQueue.stats().total_held_revisits

      assert WorkQueue.enqueue(%{ctl_domain: known, source: :ctl}) == :recently_crawled
      assert WorkQueue.stats().total_held_revisits == before + 1
      # A new name and the scheduler's own refresh still go in.
      assert WorkQueue.enqueue(%{ctl_domain: uniq("new"), source: :ctl}) == :ok
      assert WorkQueue.enqueue(%{ctl_domain: known, source: :recrawl, tier: "a"}, force: true) == :ok
    end

    test "Shopify first visits expiring: known names still queue, because priority already keeps them off the edge" do
      fv = lose(&%{ctl_domain: uniq("s#{&1}"), edge: true})
      assert fv.edge == :losing and fv.plain == :ok
      known = uniq("known")
      LS.Cluster.CrawlDedup.mark_known([known])
      assert WorkQueue.enqueue(%{ctl_domain: known, source: :ctl}) == :ok
    end
  end

  describe "the scheduler obeys it" do
    test "a lane that is behind gets no refreshes; the other keeps its share and takes nothing extra" do
      ok = %{edge: :ok, plain: :ok}
      assert Scheduler.a_split(750, ok) == {630, 120}
      assert Scheduler.a_split(750, %{ok | edge: :behind}) == {630, 0}
      assert Scheduler.a_split(750, %{ok | edge: :losing}) == {630, 0}
      assert Scheduler.a_split(750, %{ok | plain: :behind}) == {0, 120}
      assert Scheduler.a_split(750, %{edge: :losing, plain: :losing}) == {0, 0}
      assert Scheduler.a_split(0, ok) == {0, 0}
      assert Scheduler.a_split(100, ok) == {0, 100}
    end

    test "tier B and C wait while either lane is behind" do
      assert Scheduler.first_visits_ok?(%{edge: :ok, plain: :ok})
      refute Scheduler.first_visits_ok?(%{edge: :behind, plain: :ok})
      refute Scheduler.first_visits_ok?(%{edge: :ok, plain: :losing})
    end

    test "a missing or malformed health never stops the schedule" do
      for h <- [%{}, nil, "losing", %{edge: "losing"}, %{edge: nil, plain: 3}] do
        assert Scheduler.a_split(750, h) == {630, 120}, inspect(h)
        assert Scheduler.first_visits_ok?(h), inspect(h)
      end
    end
  end

  describe "the owner hears about it" do
    # The fleet as it looked when nothing was wrong (same shape as the other alert tests).
    defp metrics(queue) do
      %{
        ingestion_3h: 600_000,
        per_worker: for(i <- 1..6, do: %{worker: "worker_n#{i}@10.0.0.#{i}", rows: 180_000, http_ok_pct: 25.0, resolved_fail_pct: 6.0, classified_pct: 8.5}),
        known_workers: for(i <- 1..6, do: "worker_n#{i}@10.0.0.#{i}"),
        stale_seconds: 200,
        worker_health: %{"worker_n1@10.0.0.1" => %{quarantined: false, ratio: 0.98, dropped: 0}},
        queue: queue,
        node_resources: [{:"master@10.0.0.1", %{disk_used_pct: 60, disk_used_gb: 200, disk_total_gb: 361, mem_avail_mb: 8000}}],
        reputation_ages: %{tranco: 5, majestic: 6, blocklist: 3},
        backups: %{dir: "/home/ls/backups", sqlite_age_h: 1, product_age_h: 3, ch_age_h: 20},
        enrichment_queue: %{http_starved_streak: 0},
        verification: %{scheduler: %{running: false, disabled: false}, sources: [%{source: "yc", status: "ok", duration_s: 30, error: ""}]},
        poller: nil,
        ctl_diff: %{new: [], retired: []},
        unmonitored_nodes: [],
        watchdog_restarts: [],
        data_check: %{quality: [], quantity: [], speed: []}
      }
    end

    defp alerts(queue), do: LS.Alerts.evaluate(metrics(queue))
    defp alert_keys(fv), do: %{queue_pct: 40.0, first_visits: fv} |> alerts() |> Enum.map(& &1.key)

    test "a losing lane raises a critical alert naming the lane; behind does not" do
      base = %{edge: :ok, plain: :ok, edge_oldest_h: 3.0, plain_oldest_h: 0.1, edge_expired: 0, plain_expired: 0}
      refute "first_visits_losing_edge" in alert_keys(base)
      refute "first_visits_losing_edge" in alert_keys(%{base | edge: :behind})
      assert "first_visits_losing_edge" in alert_keys(%{base | edge: :losing, edge_expired: 140})
      assert "first_visits_losing_plain" in alert_keys(%{base | plain: :losing})

      [a] = %{queue_pct: 40.0, first_visits: %{base | edge: :losing, edge_expired: 140, edge_oldest_h: 21.5}} |> alerts() |> Enum.filter(&(&1.key == "first_visits_losing_edge"))
      assert a.severity == :critical
      assert a.line =~ "140 never-read Shopify stores expired"
      assert a.line =~ "21.5 h"
    end

    test "a queue without the health map raises nothing" do
      for q <- [%{queue_pct: 40.0}, %{queue_pct: 40.0, first_visits: nil}, %{queue_pct: 40.0, first_visits: "losing"}, nil] do
        refute Enum.any?(alerts(q), &String.starts_with?(&1.key, "first_visits_losing"))
      end

      assert alerts(%{queue_pct: 40.0, first_visits: %{edge: :ok, plain: :ok}}) == []
    end
  end
end
