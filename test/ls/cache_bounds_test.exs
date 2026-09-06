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

  2026-09-06: the eviction itself was the master's daily outage. `evict_to/3`
  copied the whole table into the inserting process (tab2list + sort), and on
  the master the table is the 5M-row CT dedup cache while the inserters are
  ~28 CT poller workers that all cross the cap in the same second: 28 copies
  of ~600 MB, BEAM 2.1 GB -> 11.9 GB in 40 s, watchdog restart, 14 times
  since 2026-08-21. The "eviction never copies the table" block pins the fix
  with a hard heap cap and a single-flight check.
  """

  @http_spec {:"$2", :"$1"}
  @bgp_spec {:"$2", {:_, :"$1"}}

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
      dropped = Cache.evict_to(:http_cache, 100, @http_spec)
      assert dropped == 100

      remaining = :ets.tab2list(:http_cache) |> Enum.map(&elem(&1, 0))
      assert length(remaining) == 100

      assert Enum.all?(remaining, &String.starts_with?(&1, "new")),
             "eviction dropped recent entries — a size cap must never weaken politeness"
    end

    test "evicting an already-small table is a no-op" do
      :ets.insert(:http_cache, {"a.example", 1})
      assert Cache.evict_to(:http_cache, 100, @http_spec) == 0
      assert :ets.info(:http_cache, :size) == 1
    end

    test "evicting a table that does not exist never raises" do
      assert Cache.evict_to(:no_such_cache_table, 10, @http_spec) == 0
    end

    test "it works for the nested BGP row shape too" do
      now = System.system_time(:second)
      :ets.insert(:bgp_cache, {"1.1.1.1", {%{asn: 1}, now - 999_999}})
      :ets.insert(:bgp_cache, {"2.2.2.2", {%{asn: 2}, now}})

      Cache.evict_to(:bgp_cache, 1, @bgp_spec)

      assert [{"2.2.2.2", _}] = :ets.tab2list(:bgp_cache)
    end
  end

  describe "eviction never copies the table (master restart root cause, 2026-09-06)" do
    # 16 MB of heap (2M words on 64-bit). The tab2list version needed ~50 MB
    # for this table and would be killed; the sampled select_delete needs
    # under 1 MB whatever the table size.
    @heap_cap_words 2_000_000

    test "evicting a 400K-row table runs inside a 16MB heap cap" do
      now = System.system_time(:second)
      for i <- 1..400_000, do: :ets.insert(:http_cache, {"d#{i}.example", now - i})

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: @heap_cap_words, kill: true, error_logger: false})
          send(parent, {:dropped, Cache.evict_to(:http_cache, 360_000, @http_spec)})
        end)

      assert_receive {:dropped, dropped}, 30_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      # Sampled cutoff: within ~1% of the exact 40,000.
      assert_in_delta dropped, 40_000, 2_000
      assert :ets.info(:http_cache, :size) == 400_000 - dropped
    end

    test "the sampled cutoff still drops the cold tail, not the recent window" do
      now = System.system_time(:second)
      # 50K old, 50K recent, distinct ages.
      for i <- 1..50_000 do
        :ets.insert(:http_cache, {"old#{i}.example", now - 5_000_000 - i})
        :ets.insert(:http_cache, {"new#{i}.example", now - i})
      end

      Cache.evict_to(:http_cache, 50_000, @http_spec)

      recent_left = :ets.select_count(:http_cache, [{{:_, :"$1"}, [{:>, :"$1", now - 1_000_000}], [true]}])
      assert recent_left == 50_000, "eviction reached into the recent window"
    end

    test "a concurrent eviction of the same table is skipped, not repeated" do
      now = System.system_time(:second)
      for i <- 1..1_000, do: :ets.insert(:http_cache, {"d#{i}.example", now - i})

      test = self()

      holder =
        spawn(fn ->
          :ets.insert(Cache.evict_lock_table(), {:http_cache, self()})
          send(test, :locked)

          receive do
            :release -> :ok
          end
        end)

      assert_receive :locked

      assert Cache.evict_to(:http_cache, 500, @http_spec) == 0,
             "a second process must not evict while another holds the table"

      assert :ets.info(:http_cache, :size) == 1_000

      send(holder, :release)
      ref = Process.monitor(holder)
      assert_receive {:DOWN, ^ref, _, _, _}

      # The dead holder's lock is stale: the next caller takes over.
      assert Cache.evict_to(:http_cache, 500, @http_spec) > 0
      assert :ets.info(:http_cache, :size) <= 510
    end

    test "a table filled within one second is trimmed to the target, not emptied" do
      # Ages are whole seconds: a burst shares one age, and a cutoff applied
      # as "everything at or below" would drop every row, including the
      # recent window politeness depends on.
      now = System.system_time(:second)
      for i <- 1..1_000, do: :ets.insert(:http_cache, {"d#{i}.example", now})

      assert Cache.evict_to(:http_cache, 900, @http_spec) == 100
      assert :ets.info(:http_cache, :size) == 900
    end

    test "thirty inserters crossing the cap together shrink the table once, not thirty times" do
      :persistent_term.put({Cache, :caps}, %{http: 1_000, rdap: 1_000, bgp: 1_000})
      now = System.system_time(:second)
      for i <- 1..1_000, do: :ets.insert(:http_cache, {"d#{i}.example", now - i})

      1..30
      |> Enum.map(fn i -> Task.async(fn -> Cache.http_insert("burst#{i}.example") end) end)
      |> Task.await_many(10_000)

      size = :ets.info(:http_cache, :size)
      # One eviction to 90% plus up to 30 inserts; thirty evictions would
      # have cut far deeper.
      assert size >= 900 and size <= 1_030, "size #{size}"
      :persistent_term.erase({Cache, :caps})
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
