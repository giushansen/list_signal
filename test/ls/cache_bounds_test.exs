defmodule LS.CacheBoundsTest do
  use ExUnit.Case, async: false

  alias LS.Cache

  @moduledoc """
  Size bounds on the politeness/BGP/RDAP caches.

  2026-08-26: these caches were bounded only by TTL — 14 days for HTTP/BGP, 90
  for RDAP — so nothing was evicted until an entry was two weeks old. Measured
  growth on a worker was ~9,800 HTTP and ~6,450 RDAP entries per HOUR, which
  projects to ~1.7 GB of ETS on nodes with 2-4 GB of RAM. Long-running workers
  drifted to ~250 MB available and swapped thousands of pages a second while a
  freshly restarted one sat at ~1.9 GB free, and the proposed "fix" was to
  redeploy the fleet periodically. These tests pin the actual fix.

  The safety property that matters: eviction is OLDEST-FIRST, so a cap can
  never drop the recent window that politeness depends on.
  """

  setup do
    for t <- [:http_cache, :rdap_cache, :bgp_cache] do
      if :ets.info(t) == :undefined, do: :ets.new(t, [:named_table, :set, :public])
      :ets.delete_all_objects(t)
    end

    :ok
  end

  describe "caps scale with the node" do
    test "a 2GB worker gets a cap that fits in ~5% of its RAM" do
      caps = Cache.compute_caps(1_968)
      total_entries = caps.http + caps.rdap + caps.bgp
      # ~110 bytes/entry measured on prod.
      mb = total_entries * 110 / 1_048_576

      assert mb <= 1_968 * 0.06, "cache budget must stay within ~5% of a 2GB node"
      assert caps.http > 50_000, "still large enough to hold a meaningful recent window"
    end

    test "a 16GB master gets proportionally more" do
      small = Cache.compute_caps(1_968)
      big = Cache.compute_caps(15_993)

      assert big.http > small.http * 4
    end

    test "every cache keeps a floor, so a tiny node never re-fetches what it just fetched" do
      caps = Cache.compute_caps(256)
      assert caps.http >= 50_000
      assert caps.rdap >= 50_000
      assert caps.bgp >= 50_000
    end

    test "an unreadable or absurd RAM figure falls back instead of crashing" do
      for bad <- [nil, 0, -1, "lots"] do
        caps = Cache.compute_caps(bad)
        assert caps.http >= 50_000
      end
    end

    test "total_ram_mb always returns a usable positive number" do
      assert is_integer(Cache.total_ram_mb()) and Cache.total_ram_mb() > 0
    end
  end

  describe "eviction is oldest-first (politeness safety)" do
    test "the recent window survives and only the cold tail is dropped" do
      now = System.system_time(:second)

      # 100 old entries and 100 recent ones, inserted interleaved.
      for i <- 1..100 do
        :ets.insert(:http_cache, {"old#{i}.example", now - 1_000_000 - i})
        :ets.insert(:http_cache, {"new#{i}.example", now - i})
      end

      assert :ets.info(:http_cache, :size) == 200
      dropped = Cache.evict_to(:http_cache, 100, &elem(&1, 1))
      assert dropped == 100

      remaining = :ets.tab2list(:http_cache) |> Enum.map(&elem(&1, 0))
      assert length(remaining) == 100

      assert Enum.all?(remaining, &String.starts_with?(&1, "new")),
             "eviction dropped recent entries — a size cap must never weaken politeness"
    end

    test "evicting an already-small table is a no-op" do
      :ets.insert(:http_cache, {"a.example", 1})
      assert Cache.evict_to(:http_cache, 100, &elem(&1, 1)) == 0
      assert :ets.info(:http_cache, :size) == 1
    end

    test "evicting a table that does not exist never raises" do
      assert Cache.evict_to(:no_such_cache_table, 10, &elem(&1, 1)) == 0
    end

    test "it works for the nested BGP row shape too" do
      now = System.system_time(:second)
      :ets.insert(:bgp_cache, {"1.1.1.1", {%{asn: 1}, now - 999_999}})
      :ets.insert(:bgp_cache, {"2.2.2.2", {%{asn: 2}, now}})

      Cache.evict_to(:bgp_cache, 1, &elem(elem(&1, 1), 1))

      assert [{"2.2.2.2", _}] = :ets.tab2list(:bgp_cache)
    end
  end

  describe "inserts stay bounded under sustained load" do
    test "hammering http_insert cannot grow the table without limit" do
      cap = Cache.compute_caps(Cache.total_ram_mb()).http
      # Drive well past a small cap by shrinking it for the test.
      :persistent_term.put({Cache, :caps}, %{http: 500, rdap: 500, bgp: 500})

      for i <- 1..2_000, do: Cache.http_insert("d#{i}.example")

      size = :ets.info(:http_cache, :size)
      assert size <= 500, "http cache grew past its cap (#{size})"
      assert size > 100, "eviction overshot and emptied the cache"

      :persistent_term.erase({Cache, :caps})
      assert is_integer(cap)
    end

    test "rdap and bgp are bounded by the same path" do
      :persistent_term.put({Cache, :caps}, %{http: 500, rdap: 400, bgp: 300})

      for i <- 1..1_500 do
        Cache.rdap_insert("r#{i}.example")
        Cache.bgp_insert("10.0.#{rem(i, 256)}.#{rem(i, 251)}", %{asn: i})
      end

      assert :ets.info(:rdap_cache, :size) <= 400
      assert :ets.info(:bgp_cache, :size) <= 300

      :persistent_term.erase({Cache, :caps})
    end
  end
end
