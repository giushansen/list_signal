defmodule LS.CacheHitRatioTest do
  use ExUnit.Case, async: false

  setup do
    # Cache is started by the app supervisor in the test env; reset counters view
    # by recording a baseline and asserting deltas.
    :ok
  end

  test "http/bgp/rdap lookups increment hit/miss counters and appear in stats" do
    base = LS.Cache.stats()
    LS.Cache.rdap_insert("hitratio-present.com")
    LS.Cache.rdap_lookup("hitratio-present.com")        # hit
    LS.Cache.rdap_lookup("hitratio-absent-#{System.unique_integer()}.com")  # miss
    s = LS.Cache.stats()

    assert s.rdap.hits >= base.rdap.hits + 1
    assert s.rdap.misses >= base.rdap.misses + 1
    assert is_integer(s.http.hits) and is_integer(s.bgp.misses)
  end

  test "fleet_hit_ratio aggregates hits/misses across worker cache snapshots" do
    caches = [
      %{rdap: %{hits: 70, misses: 30}, bgp: %{hits: 0, misses: 0}, http: %{hits: 1, misses: 0}},
      %{rdap: %{hits: 30, misses: 70}, bgp: %{hits: 0, misses: 0}, http: %{hits: 0, misses: 0}}
    ]

    # (70+30) hits / (100+100) total = 50.0%
    assert LSWeb.DashboardLive.fleet_hit_ratio(caches, :rdap) == 50.0
    assert LSWeb.DashboardLive.fleet_hit_ratio(caches, :http) == 100.0
    # no traffic -> nil (renders as "—", never a fake 0%)
    assert LSWeb.DashboardLive.fleet_hit_ratio(caches, :bgp) == nil
    assert LSWeb.DashboardLive.fleet_hit_ratio([], :rdap) == nil
  end
end
