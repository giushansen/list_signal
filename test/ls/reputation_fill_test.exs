defmodule LS.ReputationFillTest do
  use ExUnit.Case, async: false

  alias LS.Reputation

  @moduledoc """
  Master-side backfill of the Majestic columns.

  2026-08-26: every worker loaded Tranco (403 MB) AND Majestic (101 MB) into
  ETS — 504 MB on a 1,968 MB node, replicated 14 times — which is why the
  small workers hovered near their low-memory floor and emailed nightly.
  Tranco must stay (LS.HTTP.DomainFilter uses it as a crawl bypass worth
  ~150K domains per 1.5 days), but Majestic is only a data column, so the
  master fills it instead.

  The invariant that matters most here is the one from CLAUDE.md: a writer
  must never blank another writer's data.
  """

  setup do
    for t <- [:majestic_ranks, :tranco_ranks] do
      if :ets.info(t) == :undefined, do: :ets.new(t, [:named_table, :set, :public])
      :ets.delete_all_objects(t)
    end

    :ok
  end

  describe "fill/1" do
    test "fills rank and ref_subnets for a domain the master knows" do
      :ets.insert(:majestic_ranks, {"stripe.com", 412, 9_001})

      assert [row] =
               Reputation.fill([%{domain: "stripe.com", majestic_rank: nil, majestic_ref_subnets: nil}])

      assert row.majestic_rank == 412
      assert row.majestic_ref_subnets == 9_001
    end

    test "leaves an unknown domain alone rather than inventing a rank" do
      :ets.insert(:majestic_ranks, {"stripe.com", 412, 9_001})

      assert [row] = Reputation.fill([%{domain: "nobody.example", majestic_rank: nil}])
      assert row.majestic_rank == nil
    end

    test "never overwrites a rank the row already carries" do
      :ets.insert(:majestic_ranks, {"stripe.com", 412, 9_001})

      assert [row] = Reputation.fill([%{domain: "stripe.com", majestic_rank: 7, majestic_ref_subnets: 3}])
      assert row.majestic_rank == 7, "a worker-supplied rank must win over a backfill"
    end

    test "loaded?/2 with genuinely empty tables reports unloaded" do
      # Throwaway tables the real app never touches, so this proves loaded?/2's
      # logic without racing the real Tranco/Majestic GenServers' own
      # background loaders — in standalone/test mode those run for real and
      # can refill :majestic_ranks/:tranco_ranks at any moment, which is what
      # made `refute Reputation.loaded?()` against the LIVE tables an
      # intermittent failure only a fixed seed reproduced (2026-08-30).
      :ets.new(:reputation_fill_test_empty_majestic, [:set, :public])
      :ets.new(:reputation_fill_test_empty_tranco, [:set, :public])

      refute Reputation.loaded?(:reputation_fill_test_empty_majestic, :reputation_fill_test_empty_tranco)
    end

    test "unloaded master tables return rows UNTOUCHED, blanking would erase good data" do
      # domains_current is newest-row-wins: writing an empty rank over a real
      # one is the 'writer blanks another writer' failure from CLAUDE.md.
      # fill/1 is not parameterized (it calls Majestic/Tranco directly), so
      # this exercises the real tables, which this file's setup already
      # clears before every test.
      rows = [%{domain: "stripe.com", majestic_rank: 412, majestic_ref_subnets: 9_001}]
      assert Reputation.fill(rows) == rows
    end

    test "the master fills tranco_rank, which workers no longer carry" do
      :ets.insert(:tranco_ranks, {"stripe.com", 4_521})

      assert [row] = Reputation.fill([%{domain: "stripe.com", tranco_rank: nil}])
      assert row.tranco_rank == 4_521
    end

    test "a tranco_rank already on the row is never overwritten" do
      :ets.insert(:tranco_ranks, {"stripe.com", 4_521})

      assert [row] = Reputation.fill([%{domain: "stripe.com", tranco_rank: 9}])
      assert row.tranco_rank == 9
    end

    test "an unranked domain gets no tranco_rank rather than a fabricated one" do
      :ets.insert(:tranco_ranks, {"stripe.com", 4_521})

      assert [row] = Reputation.fill([%{domain: "nobody.example", tranco_rank: nil}])
      assert row.tranco_rank == nil
    end

    test "www. is normalised the same way the worker would have" do
      :ets.insert(:majestic_ranks, {"stripe.com", 412, 9_001})

      assert [row] = Reputation.fill([%{domain: "WWW.Stripe.com", majestic_rank: nil}])
      assert row.majestic_rank == 412
    end
  end

  describe "hostile input" do
    test "a row that omits the majestic keys entirely is filled, not crashed" do
      # Recrawl items and replays do not carry every column. %{row | key} would
      # raise KeyError here; Map.put does not.
      :ets.insert(:majestic_ranks, {"stripe.com", 412, 9_001})

      assert [row] = Reputation.fill([%{domain: "stripe.com"}])
      assert row.majestic_rank == 412
      assert row.majestic_ref_subnets == 9_001
    end

    test "rows without a domain, non-binary domains and non-lists never raise" do
      :ets.insert(:majestic_ranks, {"stripe.com", 412, 9_001})

      assert [_, _, _] =
               Reputation.fill([
                 %{majestic_rank: nil},
                 %{domain: nil, majestic_rank: nil},
                 %{domain: 12_345, majestic_rank: nil}
               ])

      assert Reputation.fill(:not_a_list) == :not_a_list
      assert Reputation.fill([]) == []
    end

    test "a worker without the Majestic table gets nil instead of an exception" do
      # This is the whole point: workers no longer supervise Majestic.
      if :ets.info(:majestic_ranks) != :undefined, do: :ets.delete(:majestic_ranks)

      assert LS.Reputation.Majestic.lookup("stripe.com") == nil

      :ets.new(:majestic_ranks, [:named_table, :set, :public])
    end
  end
end
