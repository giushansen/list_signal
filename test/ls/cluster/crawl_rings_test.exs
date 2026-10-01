defmodule LS.Cluster.CrawlRingsTest do
  @moduledoc """
  Three rings beside the daily blooms (2026-10-01): dormant (60-90 days
  for twice-unchanged businesses and name-settled skips), hot (a recorded
  change puts a domain back on 7 days) and the stable ring from
  2026-09-09. The gate consults them in the order hot > dormant > stable >
  daily. Rings survive a restart and advance by the time the BEAM was down.
  """
  use ExUnit.Case, async: false

  alias LS.Cluster.{CrawlDedup, WorkQueue}

  setup do
    for name <- [:stable, :dormant, :hot] do
      :persistent_term.put({CrawlDedup, name}, %{blooms: fresh(name), rotated_at: System.system_time(:second)})
    end

    :ok
  end

  defp fresh(:stable), do: for(_ <- 1..5, do: LS.Reputation.Bloom.new(10_000, 0.001))
  defp fresh(:dormant), do: for(_ <- 1..3, do: LS.Reputation.Bloom.new(10_000, 0.02))
  defp fresh(:hot), do: for(_ <- 1..4, do: LS.Reputation.Bloom.new(10_000, 0.01))

  test "a dormant domain is suppressed and its sighting recorded, even when forced" do
    assert CrawlDedup.mark_dormant(["sleepy.example", "", nil]) == 1
    assert CrawlDedup.dormant?("sleepy.example")
    refute CrawlDedup.dormant?("awake.example")
    assert WorkQueue.enqueue(%{ctl_domain: "sleepy.example"}, force: true) == :recently_crawled
  end

  test "a hot domain ignores the dormant and stable rings" do
    CrawlDedup.mark_dormant(["moving.example"])
    CrawlDedup.mark_stable(["moving.example"])
    assert CrawlDedup.mark_hot(["moving.example"]) == 1
    assert CrawlDedup.hot?("moving.example")
    # Past the slow rings; the daily bloom then decides like any domain.
    result = WorkQueue.enqueue(%{ctl_domain: "moving.example"}, force: true)
    assert result in [:ok, :queue_full]
  end

  test "the dormant ring advances by whole months while down and forgets after three" do
    now = System.system_time(:second)
    month = 30 * 86_400
    [b1 | _] = blooms = fresh(:dormant)
    LS.Reputation.Bloom.put(b1, "old.example")
    ring = %{blooms: blooms, rotated_at: now - 2 * month - 10}

    rotated = CrawlDedup.rotate_ring(:dormant, ring, now)
    assert rotated.rotated_at == ring.rotated_at + 2 * month
    assert Enum.at(rotated.blooms, 2) == b1, "the old bloom slid to the last slot"

    gone = CrawlDedup.rotate_ring(:dormant, ring, now + month)
    refute Enum.any?(gone.blooms, &LS.Reputation.Bloom.member?(&1, "old.example"))
  end

  test "rings round-trip through their files" do
    dir = Path.join(System.tmp_dir!(), "ls_rings_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = Application.get_env(:ls, :state_dir)
    Application.put_env(:ls, :state_dir, dir)

    try do
      CrawlDedup.mark_dormant(["saved.example"])
      CrawlDedup.mark_hot(["warm.example"])
      assert :ok = CrawlDedup.save_ring(:dormant)
      assert :ok = CrawlDedup.save_ring(:hot)

      {:ok, ring} = CrawlDedup.decode_ring(:dormant, File.read!(CrawlDedup.ring_path(:dormant)), System.system_time(:second))
      assert Enum.any?(ring.blooms, &LS.Reputation.Bloom.member?(&1, "saved.example"))
      {:ok, hot} = CrawlDedup.decode_ring(:hot, File.read!(CrawlDedup.ring_path(:hot)), System.system_time(:second))
      assert Enum.any?(hot.blooms, &LS.Reputation.Bloom.member?(&1, "warm.example"))
      assert CrawlDedup.decode_ring(:dormant, <<1, 2, 3>>, 0) == {:error, :corrupt}
    after
      if old, do: Application.put_env(:ls, :state_dir, old), else: Application.delete_env(:ls, :state_dir)
      File.rm_rf!(dir)
    end
  end

  test "stats expose every ring" do
    stats = CrawlDedup.stats()
    for k <- [:stable_windows, :dormant_windows, :hot_windows, :dormant_marked_total, :hot_entries], do: assert(Map.has_key?(stats, k), "#{k}")
    assert stats.dormant_windows == 3
    assert stats.hot_windows == 4
  end

  test "the queue remembers a batch's verdicts: settled skips sleep, mail-less ones wait a month, all count as handled" do
    WorkQueue.remember_skipped(%{dormant: ["tld.top"], soft: ["nomail.com"], recent: ["seen.com"], unresolved: ["nx.com"]})
    assert CrawlDedup.dormant?("tld.top")
    refute CrawlDedup.dormant?("nomail.com")
    assert CrawlDedup.stable?("nomail.com")
    for d <- ~w(tld.top nomail.com seen.com nx.com), do: assert(WorkQueue.recently_crawled?(d), d)
  end
end
