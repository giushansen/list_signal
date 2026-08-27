defmodule LS.ApplicationBootOrderTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Boot order that the product's post-deploy behaviour depends on.

  2026-08-24: a deploy returned a 25-second `503` on /top/fashion with a load
  average of 39.9, because the caches are what keep ClickHouse read CPU at ~0.9
  cores and ETS is empty after every restart. `LS.CacheSnapshot` fixes that by
  restoring the caches at boot — but ONLY if it finishes before the endpoint
  starts accepting requests. Move it below `LSWeb.Endpoint` and the fix
  silently stops working: the app still boots, the snapshot is still written
  and read, and the first visitors still pay for a cold cache.

  Nothing else in the codebase can catch that, so it is asserted structurally.
  """

  @source File.read!("lib/ls/application.ex")

  # Position of a child *as a list entry* — matched with its leading newline and
  # indentation, so an incidental mention elsewhere in the module (e.g.
  # `Process.whereis(LSWeb.Endpoint)` in config_change/2) is not mistaken for
  # its position in the supervision tree.
  defp position(child) do
    case :binary.match(@source, "\n      " <> child) do
      {i, _} -> i
      :nomatch -> flunk("#{child} is no longer a child in the supervision tree")
    end
  end

  test "the cache is restored before the endpoint accepts requests" do
    assert position("LS.CacheSnapshot") < position("LSWeb.Endpoint"),
           "LS.CacheSnapshot must start BEFORE LSWeb.Endpoint, or the first " <>
             "requests after a deploy hit a cold cache — the 2026-08-24 503."
  end

  test "the cache is restored after the tables it restores into exist" do
    assert position("LS.UICache") < position("LS.CacheSnapshot"),
           "LS.UICache creates :ls_ui_cache; restoring before it exists is a no-op."

    assert position("{LS.LandingCache, []}") < position("LS.CacheSnapshot"),
           "LS.LandingCache creates :landing_cache; restoring before it exists is a no-op."
  end

  test "workers keep Tranco but not Majestic — Tranco is a crawl decision, Majestic is a column" do
    # 2026-08-26: workers loaded 504MB of reference data (Tranco 403 + Majestic
    # 101) on nodes with 1,968MB total. Majestic moved to a master-side
    # backfill; Tranco MUST stay because LS.HTTP.DomainFilter uses it as a
    # crawl bypass worth ~150K domains per 1.5 days. Re-adding Majestic to the
    # worker list silently costs every small node 101MB again.
    worker_block =
      @source
      |> String.split("defp role_children(\"worker\"")
      |> Enum.at(1)
      |> String.split("defp role_children(\"standalone\"")
      |> List.first()

    assert worker_block =~ "LS.Reputation.Tranco",
           "Tranco is the crawl-bypass source; workers need it"

    refute worker_block =~ "LS.Reputation.Majestic,",
           "Majestic is backfilled by the master (LS.Reputation.fill/1) — 101MB per worker"
  end

  test "the queue trend sampler starts after the queue it samples" do
    assert position("LS.Cluster.WorkQueue,") < position("LS.Cluster.QueueTrend"),
           "QueueTrend samples WorkQueue.stats/0 on start."
  end
end
