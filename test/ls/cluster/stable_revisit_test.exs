defmodule LS.Cluster.StableRevisitTest do
  use ExUnit.Case, async: false

  alias LS.Cluster.CrawlDedup
  alias LS.Reputation.Bloom

  @moduledoc """
  Change-aware revisits (2026-09-09). Measured on prod: 73.9% of crawls in a
  week are revisits and 88.9% of revisits at least 7 days apart come back
  unchanged, so two thirds of the fleet's fetches confirmed that nothing had
  changed. A domain the compactor saw come back unchanged waits 28-35 days
  before the next fetch, whoever asks; a changed one returns to the weekly
  cadence. The ring survives a master restart.
  """

  @stable_key {LS.Cluster.CrawlDedup, :stable}
  @daily_key {LS.Cluster.CrawlDedup, :blooms}

  setup do
    saved = :persistent_term.get(@stable_key, nil)
    saved_daily = :persistent_term.get(@daily_key, nil)
    saved_flag = Application.get_env(:ls, :stable_revisit)

    on_exit(fn ->
      if saved, do: :persistent_term.put(@stable_key, saved), else: :persistent_term.erase(@stable_key)
      if saved_daily, do: :persistent_term.put(@daily_key, saved_daily), else: :persistent_term.erase(@daily_key)
      if saved_flag == nil, do: Application.delete_env(:ls, :stable_revisit), else: Application.put_env(:ls, :stable_revisit, saved_flag)
    end)

    Application.put_env(:ls, :stable_revisit, true)
    :persistent_term.put(@daily_key, for(_ <- 1..8, do: Bloom.new(10_000, 0.01)))
    :persistent_term.put(@stable_key, %{blooms: for(_ <- 1..5, do: Bloom.new(10_000, 0.001)), rotated_at: System.system_time(:second)})
    :ok
  end

  test "an unchanged domain is skipped even when the recrawl scheduler forces it" do
    refute CrawlDedup.stable?("calm.example")
    assert CrawlDedup.mark_stable(["calm.example", "", nil]) == 1
    assert CrawlDedup.stable?("calm.example")

    assert :recently_crawled = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "calm.example", source: :recrawl}, force: true)
    assert :recently_crawled = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "calm.example", source: :ctl})
    assert LS.Cluster.WorkQueue.stats().total_deduped_stable >= 2
  end

  test "a domain never marked stable keeps the 7-day cadence" do
    assert :ok = LS.Cluster.WorkQueue.enqueue(%{ctl_domain: "busy.example", source: :recrawl}, force: true)
  end

  test "the flag turns the gate off without losing the ring" do
    CrawlDedup.mark_stable(["flagged.example"])
    Application.put_env(:ls, :stable_revisit, false)
    refute CrawlDedup.stable?("flagged.example")
    Application.put_env(:ls, :stable_revisit, true)
    assert CrawlDedup.stable?("flagged.example")
  end

  describe "rotation" do
    test "four weekly rotations keep a mark, five release it (28 to 35 days)" do
      now = System.system_time(:second)
      ring = :persistent_term.get(@stable_key)
      CrawlDedup.mark_stable(["month.example"])

      four = CrawlDedup.rotate_stable_ring(ring, now + 4 * 7 * 86_400)
      assert Enum.any?(four.blooms, &Bloom.member?(&1, "month.example"))
      assert four.rotated_at == ring.rotated_at + 4 * 7 * 86_400

      five = CrawlDedup.rotate_stable_ring(ring, now + 5 * 7 * 86_400)
      refute Enum.any?(five.blooms, &Bloom.member?(&1, "month.example"))
      assert length(five.blooms) == 5
    end

    test "less than a week is no rotation" do
      ring = :persistent_term.get(@stable_key)
      assert CrawlDedup.rotate_stable_ring(ring, ring.rotated_at + 6 * 86_400) == ring
    end
  end

  describe "the ring survives a restart" do
    test "a bloom round-trips through its binary form" do
      b = Bloom.new(1_000, 0.001)
      Bloom.put(b, "a.example")
      Bloom.put(b, "b.example")
      assert {:ok, back} = Bloom.from_binary(Bloom.to_binary(b))
      assert Bloom.member?(back, "a.example")
      assert Bloom.member?(back, "b.example")
      refute Bloom.member?(back, "c.example")
      assert Bloom.count(back) == 2
      assert Bloom.from_binary(<<1, 2, 3>>) == :error
      assert Bloom.from_binary(:erlang.term_to_binary({:bloom, 1, 64, 1, 0, "short"})) == :error
    end

    test "save, then decode with time passed, gives a rotated ring with the marks intact" do
      dir = Path.join(System.tmp_dir!(), "ls_stable_#{System.unique_integer([:positive])}")
      saved = Application.get_env(:ls, :state_dir)
      Application.put_env(:ls, :state_dir, dir)
      on_exit(fn -> File.rm_rf!(dir); if saved, do: Application.put_env(:ls, :state_dir, saved), else: Application.delete_env(:ls, :state_dir) end)

      CrawlDedup.mark_stable(["persist.example"])
      assert :ok = CrawlDedup.save_stable()
      bin = File.read!(CrawlDedup.stable_path())

      at = :persistent_term.get(@stable_key).rotated_at
      assert {:ok, ring} = CrawlDedup.decode_stable(bin, at + 2 * 7 * 86_400)
      assert ring.rotated_at == at + 2 * 7 * 86_400
      assert Enum.any?(ring.blooms, &Bloom.member?(&1, "persist.example"))
      assert length(ring.blooms) == 5

      assert {:error, :corrupt} = CrawlDedup.decode_stable("garbage", at)
    end
  end

  describe "which domains count as unchanged" do
    test "the query compares the four shown fields, requires an observed 2xx/3xx crawl and spares the top 100K" do
      sql = LS.Clickhouse.stable_domains_sql(1_700_000_000, 1_700_000_300)
      assert sql =~ "argMax(http_title, enriched_at)"
      assert sql =~ "n.title = o.http_title AND n.tech = o.http_tech AND n.apps = o.http_apps AND n.status = o.http_status"
      assert sql =~ "http_observed = 1", "a bot wall served as 200 must never mark a site as unchanged"
      assert sql =~ "tranco_rank IS NULL OR o.tranco_rank > 100000", "what customers look at keeps the weekly cadence"
      assert sql =~ "max_execution_time = 115", "dies with the compactor's client like the signals query"
      assert sql =~ "enriched_at >= toDateTime(1700000000) AND enriched_at < toDateTime(1700000300)"
    end
  end
end
