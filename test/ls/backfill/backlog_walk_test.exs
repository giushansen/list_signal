defmodule LS.Backfill.BacklogWalkTest do
  @moduledoc """
  2026-11-12: two backlogs found by measuring, both walked over sorted
  domain ranges because `enrich_log` (501M rows, 87 GB) is sorted by
  domain and a range predicate reads only its granules.

    * 2.72M domains resolved to Shopify and were never fetched. Of those a
      renewal brought back in 24 h, 94.7% answered 200 and 20.2% had an
      email. `LS.Recrawl.EdgeBackfill` feeds them into room the Shopify
      line has left after first visits and refreshes.
    * About 3.7M sites read in English or French, with an email, have no
      `businesses` row (09-07 to 10-03 only labelled sites became rows).
      `LS.Backfill.Membership` compiles them from their own history.

  A walk that skipped a range, read one twice, or put a hostile name in
  its SQL would lose stores or break a batch, so those are pinned here.
  """
  use ExUnit.Case, async: true

  alias LS.Backfill.{Membership, Ranges}
  alias LS.Recrawl.EdgeBackfill

  # Which range a domain falls in, by the same rule the SQL applies.
  defp range_of(domain) do
    Ranges.all()
    |> Enum.with_index()
    |> Enum.filter(fn {{lo, hi}, _} -> domain >= lo and (is_nil(hi) or domain < hi) end)
    |> Enum.map(&elem(&1, 1))
  end

  describe "ranges" do
    test "cover every name exactly once, sorted, with no gap" do
      all = Ranges.all()
      assert {"", _} = hd(all)
      assert {_, nil} = List.last(all)
      assert Ranges.count() == length(all)

      for {{_, hi}, {lo, _}} <- Enum.zip(all, tl(all)), do: assert(hi == lo)
      los = Enum.map(all, &elem(&1, 0))
      assert los == Enum.sort(los)

      for d <- ~w(a.com be.com bennett.com 0day.io xn--bcher-kva.de zz.top zzzz.com - . 9 ~weird ÿ.com) do
        assert [_] = range_of(d), d
      end
    end

    test "a page reads inside its range and past the cursor" do
      {lo, hi} = Ranges.at(10)
      sql = Ranges.where_sql({lo, hi}, "shop.example")
      assert sql =~ "domain >= '#{lo}'"
      assert sql =~ "domain < '#{hi}'"
      assert sql =~ "domain > 'shop.example'"
      assert Ranges.where_sql({"zz", nil}, nil) == "domain >= 'zz'"
      assert Ranges.where_sql({"", "--"}, "") == "domain >= '' AND domain < '--'"
      assert Ranges.at(Ranges.count()) == nil
      assert Ranges.at(-1) == nil
    end

    test "a quote or backslash never reaches the SQL" do
      assert_raise ArgumentError, fn -> Ranges.where_sql({"a", "b"}, "x' OR 1=1 --") end
      assert_raise ArgumentError, fn -> Ranges.where_sql({"a", "b"}, "x\\") end
    end

    test "a full page stays in its range, a short one moves on, the last one ends" do
      page = Enum.map(1..3, &"d#{&1}.com")
      assert Ranges.advance({5, nil}, page, 3) == {5, "d3.com"}
      assert Ranges.advance({5, "x"}, Enum.take(page, 2), 3) == {6, nil}
      assert Ranges.advance({5, "x"}, [], 3) == {6, nil}
      assert Ranges.advance({Ranges.count() - 1, nil}, [], 3) == :done
    end

    test "hostile names from ClickHouse are dropped before any SQL sees them" do
      long = String.duplicate("a", 254) <> ".com"
      rows = [["ok.com"], ["it's.com"], ["back\\slash.com"], ["new\nline.com"], ["tab\t.com"], [<<"nul", 0, ".com">>], [""], [nil], [42], [long], "bare.com", []]
      assert Ranges.safe_domains(rows) == ["ok.com", "bare.com"]
      assert Ranges.safe_domains(nil) == []
      assert Ranges.safe_domains("x") == []
    end

    test "a cursor survives a restart, and a corrupt or hostile file starts over" do
      dir = Path.join(System.tmp_dir!(), "ranges-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "c.bin")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Ranges.load(path) == {0, nil}
      :ok = Ranges.save(path, {42, "shop.example"})
      assert Ranges.load(path) == {42, "shop.example"}

      for junk <- ["not a term", :erlang.term_to_binary({-1, nil}), :erlang.term_to_binary({1, 2}), :erlang.term_to_binary(:other), ""] do
        File.write!(path, junk)
        assert Ranges.load(path) == {0, nil}
      end
    end
  end

  describe "Shopify backlog feeder" do
    @ok %{edge: :ok, plain: :ok}
    @quiet %{queue_depth_edge_sightings: 0, queue_depth_priority: 0, queue_depth_backfill: 0}

    test "reads only into room: first visits on time, little ahead of it, little of it waiting" do
      assert EdgeBackfill.feed?(@ok, @quiet)
      refute EdgeBackfill.feed?(%{@ok | edge: :behind}, @quiet)
      refute EdgeBackfill.feed?(%{@ok | edge: :losing}, @quiet)
      # The plain lane is not the Shopify line's business.
      assert EdgeBackfill.feed?(%{@ok | plain: :losing}, @quiet)
      # 2026-11-11: 16,061 first visits and 14,637 refreshes waited; no room.
      refute EdgeBackfill.feed?(@ok, %{@quiet | queue_depth_edge_sightings: 16_061, queue_depth_priority: 14_637})
      refute EdgeBackfill.feed?(@ok, %{@quiet | queue_depth_edge_sightings: 1_000, queue_depth_priority: 1_000})
      assert EdgeBackfill.feed?(@ok, %{@quiet | queue_depth_edge_sightings: 999, queue_depth_priority: 1_000})
      refute EdgeBackfill.feed?(@ok, %{@quiet | queue_depth_backfill: 3_000})
    end

    test "garbage stats or health never start a feed" do
      refute EdgeBackfill.feed?(nil, @quiet)
      refute EdgeBackfill.feed?(@ok, nil)
      assert EdgeBackfill.feed?(@ok, %{queue_depth_edge_sightings: "lots", queue_depth_priority: -5})
      refute EdgeBackfill.feed?(%{edge: "ok"}, @quiet)
    end

    test "a backlog item sorts behind refreshes and is not a first visit" do
      item = EdgeBackfill.item("shop.example")
      assert item == %{ctl_domain: "shop.example", source: :backfill, edge: true}
      assert LS.Cluster.WorkQueue.priority(item) == 1
      refute LS.Cluster.WorkQueue.first_visit?(item)
      assert LS.Cluster.WorkQueue.edge?(item)
    end

    test "the page asks for stores behind Shopify's edge, never fetched, seen lately, in its range" do
      sql = EdgeBackfill.page_sql({3, "abc.com"})
      {lo, hi} = Ranges.at(3)
      assert sql =~ "FROM enrich_log"
      assert sql =~ "domain >= '#{lo}' AND domain < '#{hi}' AND domain > 'abc.com'"
      assert sql =~ "startsWith(bgp_ip, '23.227.38.')"
      assert sql =~ "max(coalesce(http_status, 0) > 0) = 0"
      assert sql =~ "ORDER BY domain"
      assert sql =~ "LIMIT 2000"
      assert sql =~ "max_execution_time"
    end
  end

  describe "membership backfill" do
    test "the page selects readable EN/FR sites with an email and no businesses row, in its range" do
      sql = Membership.page_sql({7, nil})
      {lo, hi} = Ranges.at(7)
      assert sql =~ "domain >= '#{lo}' AND domain < '#{hi}'"
      assert sql =~ "NOT IN (SELECT domain FROM businesses WHERE domain >= '#{lo}' AND domain < '#{hi}')"
      assert sql =~ "(lang LIKE 'en%' OR lang LIKE 'fr%')"
      assert sql =~ "junk = ''"
      assert sql =~ "title != ''"
      assert sql =~ "is_malware != '' OR is_phishing != ''"
      assert sql =~ "http_observed = 1"
      assert sql =~ "LIMIT 2000"
      refute sql =~ "http_language LIKE"
    end

    test "it only runs when started by hand" do
      assert Membership.status() == %{running: false}
    end
  end
end
