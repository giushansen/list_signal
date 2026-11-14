defmodule LS.Recrawl.LeanModeTest do
  @moduledoc """
  2026-11-14, owner: half the workers go, and the crawl must keep finding
  new businesses. Measured before the cut: half of 200K rows a day went to
  sites read successfully 40 to 75 days earlier, re-read because their
  certificate renewed, and produced no new business. Lean mode
  (`LS_CRAWL_MODE=lean`) holds those sightings and stretches Shopify
  refreshes to 90 days; three workers do about 82K fetches a day.

  What must never happen: a first visit held back, the scheduler's own
  refreshes held back, a hostile name reaching the lookup's SQL, or a bad
  answer from ClickHouse dropping a sighting. And unset, nothing changes.
  """
  use ExUnit.Case, async: true

  alias LS.Crawl.{Lean, Tiers}
  alias LS.Recrawl.LeanGate

  describe "the switch" do
    test "is on only for LS_CRAWL_MODE=lean" do
      assert Lean.on?("lean")
      for off <- [nil, "", "full", "LEAN", "on", "true", "lean "], do: refute(Lean.on?(off), inspect(off))
    end

    test "Shopify stores are refreshed every 90 days in lean mode and every 28 without it" do
      assert Tiers.shopify_a_days(false) == 28
      assert Tiers.shopify_a_days(true) == 90
      assert Lean.reread_days() == 120
    end
  end

  describe "which sightings go through the lookup" do
    @sighting %{ctl_domain: "shop.example", source: :ctl}

    test "a certificate sighting does, in lean mode only" do
      assert LeanGate.divert?(@sighting, [], false, true)
      refute LeanGate.divert?(@sighting, [], false, false)
      assert LeanGate.divert?(%{ctl_domain: "shop.example", edge: true}, [], false, true)
      assert LeanGate.divert?(%{ctl_domain: "shop.example", known: true}, [], false, true)
    end

    test "the scheduler's refreshes and the never-fetched backlog never do" do
      refute LeanGate.divert?(%{ctl_domain: "shop.example", source: :recrawl}, [force: true], false, true)
      refute LeanGate.divert?(%{ctl_domain: "shop.example", source: :recrawl}, [], false, true)
      refute LeanGate.divert?(@sighting, [force: true], false, true)
      refute LeanGate.divert?(LS.Recrawl.EdgeBackfill.item("shop.example"), [], false, true)
    end

    test "a business that just changed keeps its 7 days, and a checked sighting is not checked twice" do
      refute LeanGate.divert?(@sighting, [], true, true)
      refute LeanGate.divert?(@sighting, [lean_checked: true], false, true)
    end

    test "garbage is never diverted" do
      refute LeanGate.divert?(nil, [], false, true)
      refute LeanGate.divert?("shop.example", [], false, true)
      refute LeanGate.divert?(@sighting, :force, false, true)
    end

    test "without the switch the gate holds nothing, whether or not its process runs" do
      # The suite runs without LS_CRAWL_MODE: enqueue/2 must behave as it
      # did before lean mode existed.
      refute Lean.on?()

      case LeanGate.stats() do
        %{running: true} = s -> assert s.lean == false and s.buffer == 0 and s.held == 0
        other -> assert other == %{running: false}
      end
    end
  end

  describe "the lookup" do
    test "asks for sites read with a 200 inside the window, by name" do
      sql = LeanGate.lookup_sql(["a.com", "b.co.uk"], 120)
      assert sql =~ "FROM enrich_log"
      assert sql =~ "domain IN ('a.com', 'b.co.uk')"
      assert sql =~ "INTERVAL 120 DAY"
      assert sql =~ "http_status = 200"
      assert sql =~ "max_execution_time"
    end

    test "holds what was read, passes everything else" do
      buffer = %{"read.com" => %{ctl_domain: "read.com"}, "new.com" => %{ctl_domain: "new.com"}, "dead.com" => %{ctl_domain: "dead.com"}}
      {held, passed} = LeanGate.split(buffer, [["read.com"]])
      assert held == [%{ctl_domain: "read.com"}]
      assert Enum.sort_by(passed, & &1.ctl_domain) == [%{ctl_domain: "dead.com"}, %{ctl_domain: "new.com"}]
    end

    test "a bad answer from ClickHouse can only let sightings through" do
      buffer = %{"new.com" => %{ctl_domain: "new.com"}, "it's.com" => %{ctl_domain: "it's.com"}}

      for answer <- [nil, "new.com", %{}, [], [[]], [[nil]], [[42]], [["other.com"]], [["it's.com"]], [[String.duplicate("a", 300)]]] do
        assert {[], passed} = LeanGate.split(buffer, answer), inspect(answer)
        assert length(passed) == 2
      end

      assert LeanGate.split(%{}, [["new.com"]]) == {[], []}
    end
  end
end
