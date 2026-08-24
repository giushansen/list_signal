defmodule LS.CacheSnapshotTest do
  use ExUnit.Case, async: false

  alias LS.CacheSnapshot

  @moduledoc """
  Pins the post-deploy cache restore.

  2026-08-24: caching cut ClickHouse read CPU from 13.7 cores to 0.86, and in
  doing so made every deploy a cold start. The deploy that shipped it returned
  a 25-second 503 on /top/fashion with a load average of 39.9. Persisting the
  caches removes that window — but ONLY if a restore can never serve data
  staler than the TTL promised, which is what most of these tests check.
  """

  setup do
    path = Path.join(System.tmp_dir!(), "ls_snapshot_test_#{System.unique_integer([:positive])}.bin")
    Application.put_env(:ls, :cache_snapshot_path, path)

    for t <- [:ls_ui_cache, :landing_cache] do
      if :ets.info(t) == :undefined, do: :ets.new(t, [:named_table, :set, :public])
      :ets.delete_all_objects(t)
    end

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
      Application.delete_env(:ls, :cache_snapshot_path)
    end)

    %{path: path}
  end

  describe "round trip" do
    test "a saved UICache entry comes back with its value intact" do
      now = System.system_time(:second)
      :ets.insert(:ls_ui_cache, {{:tech_page, "shopify"}, {:ok, %{stores: 700_000}}, now + 3_600, now})

      assert {:ok, 1} = CacheSnapshot.save()
      :ets.delete_all_objects(:ls_ui_cache)
      assert CacheSnapshot.restore() == 1

      assert [{_, {:ok, %{stores: 700_000}}, _, _}] =
               :ets.lookup(:ls_ui_cache, {:tech_page, "shopify"})
    end

    test "a LandingCache entry round-trips despite monotonic expiry being meaningless across a restart" do
      mono = System.monotonic_time(:millisecond)
      :ets.insert(:landing_cache, {{:name, "klaviyo"}, {:ok, [1, 2, 3]}, mono + 3_600_000})

      assert {:ok, 1} = CacheSnapshot.save()
      :ets.delete_all_objects(:landing_cache)
      assert CacheSnapshot.restore() == 1

      [{_, value, expires_at}] = :ets.lookup(:landing_cache, {:name, "klaviyo"})
      assert value == {:ok, [1, 2, 3]}
      # Rebuilt against THIS boot's monotonic clock, so it must be in the future.
      assert expires_at > System.monotonic_time(:millisecond)
    end
  end

  describe "a restore can never extend freshness" do
    test "downtime is charged against the remaining TTL" do
      # 60 min left at save; 20 min of downtime => at most 40 min left.
      left = CacheSnapshot.rebuild(:k, :v, 3_600_000, 1_200_000, :wall_4, 0, 0, 0.0)
      assert {:k, :v, expires_at, 0} = left
      assert expires_at <= 2_400
    end

    test "an entry whose TTL expired during the downtime is dropped, not resurrected" do
      # 5 min left, 10 min down.
      assert CacheSnapshot.rebuild(:k, :v, 300_000, 600_000, :wall_4, 0, 0, 0.0) == nil
    end

    test "jitter only ever shortens a TTL, never lengthens it" do
      for j <- [0.0, 0.25, 0.5, 0.75, 0.999] do
        {_, _, expires_at, _} = CacheSnapshot.rebuild(:k, :v, 3_600_000, 0, :wall_4, 0, 0, j)
        assert expires_at <= 3_600, "jitter #{j} extended the TTL"
        assert expires_at >= 2_700, "jitter #{j} shortened by more than 25%"
      end
    end

    test "a snapshot older than the max age is ignored entirely" do
      now = System.system_time(:second)
      :ets.insert(:ls_ui_cache, {{:tech_page, "x"}, {:ok, 1}, now + 86_400, now})
      assert {:ok, 1} = CacheSnapshot.save()

      # Rewrite the file's saved_at to seven hours ago (cap is six).
      %{tables: tables} = :erlang.binary_to_term(File.read!(CacheSnapshot.path()))
      stale = %{saved_at: System.system_time(:millisecond) - :timer.hours(7), tables: tables}
      File.write!(CacheSnapshot.path(), :erlang.term_to_binary(stale))

      :ets.delete_all_objects(:ls_ui_cache)
      assert CacheSnapshot.restore() == 0
      assert :ets.info(:ls_ui_cache, :size) == 0
    end

    test "an entry already recomputed since boot is never overwritten by an older snapshot value" do
      now = System.system_time(:second)
      :ets.insert(:ls_ui_cache, {{:tech_page, "x"}, {:ok, :old}, now + 3_600, now})
      assert {:ok, 1} = CacheSnapshot.save()

      :ets.delete_all_objects(:ls_ui_cache)
      :ets.insert(:ls_ui_cache, {{:tech_page, "x"}, {:ok, :fresh}, now + 3_600, now})
      CacheSnapshot.restore()

      assert [{_, {:ok, :fresh}, _, _}] = :ets.lookup(:ls_ui_cache, {:tech_page, "x"})
    end
  end

  describe "staggering" do
    test "keys warmed together do not expire together" do
      # The warmer inserts ~180 keys back to back with one TTL. Without jitter
      # they all expire in the same second and re-create the stampede the cache
      # exists to prevent.
      expiries =
        for i <- 1..200 do
          {_, _, e, _} = CacheSnapshot.rebuild({:tech_page, i}, :v, 21_600_000, 0, :wall_4, 0, 0)
          e
        end

      assert Enum.uniq(expiries) |> length() > 100, "restored TTLs are not spread out"
      assert Enum.max(expiries) - Enum.min(expiries) > 1_800, "spread is under 30 minutes"
    end
  end

  describe "hostile input" do
    test "a corrupt snapshot file returns 0 instead of crashing the boot", %{path: path} do
      File.write!(path, "this is not erlang term format at all")
      assert CacheSnapshot.restore() == 0
    end

    test "a truncated snapshot returns 0 instead of crashing the boot", %{path: path} do
      now = System.system_time(:second)
      :ets.insert(:ls_ui_cache, {{:tech_page, "x"}, {:ok, 1}, now + 3_600, now})
      CacheSnapshot.save()
      bin = File.read!(path)
      File.write!(path, binary_part(bin, 0, div(byte_size(bin), 2)))

      assert CacheSnapshot.restore() == 0
    end

    test "a missing snapshot file is a normal cold boot, not an error" do
      File.rm(CacheSnapshot.path())
      assert CacheSnapshot.restore() == 0
    end

    test "rows that are not cache entries are never persisted" do
      # landing_cache also holds {:landing, data} and {:tech_names, list} for its
      # own refresh loop. Those belong to the GenServer, not to the snapshot.
      :ets.insert(:landing_cache, {:landing, %{stores: 1}})
      :ets.insert(:landing_cache, {:tech_names, [{"a", 1}]})

      assert {:ok, 0} = CacheSnapshot.save()
    end

    test "an already-expired entry is not written to the file" do
      now = System.system_time(:second)
      :ets.insert(:ls_ui_cache, {{:tech_page, "stale"}, {:ok, 1}, now - 10, now - 3_600})

      assert {:ok, 0} = CacheSnapshot.save()
    end

    test "a save leaves no .tmp file behind", %{path: path} do
      now = System.system_time(:second)
      :ets.insert(:ls_ui_cache, {{:tech_page, "x"}, {:ok, 1}, now + 3_600, now})
      CacheSnapshot.save()

      refute File.exists?(path <> ".tmp")
    end

    test "saving with no tables present does not raise" do
      assert {:ok, 0} = CacheSnapshot.save()
    end
  end

  describe "pure entry_remaining/4" do
    test "computes milliseconds left for both row shapes and drops foreign rows" do
      assert CacheSnapshot.entry_remaining({:k, :v, 100, 0}, :wall_4, 40, nil) == [{:k, :v, 60_000}]
      assert CacheSnapshot.entry_remaining({:k, :v, 5_000}, :mono_3, nil, 1_000) == [{:k, :v, 4_000}]
      assert CacheSnapshot.entry_remaining({:landing, %{}}, :mono_3, nil, 0) == []
      assert CacheSnapshot.entry_remaining({:k, :v, 10, 0}, :wall_4, 40, nil) == []
    end
  end
end
