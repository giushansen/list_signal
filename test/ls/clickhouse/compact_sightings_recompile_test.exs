defmodule LS.Clickhouse.CompactSightingsRecompileTest do
  @moduledoc """
  2026-10-24, the owner's condition for suppressing re-fetches of known
  businesses: their hostnames must still be recorded. A suppressed sighting
  was already written to ctl_log and the fold already unioned those hosts,
  but a pass only recompiled what enrich_log touched, so a new "app." or
  "careers." host on a business the rings kept from being fetched waited
  for its next fetch, up to its whole cadence. The compaction domain set now
  includes businesses whose window sightings name a host they do not have.
  """
  use ExUnit.Case, async: true

  alias LS.Clickhouse.Compact

  test "the leg finds businesses whose sightings carry a host the compiled row lacks" do
    sql = Compact.sightings_with_new_hosts_sql(1_700_000_000, 1_700_003_600)
    assert sql =~ "FROM ctl_log WHERE seen_at >= toDateTime(1700000000) AND seen_at < toDateTime(1700003600) GROUP BY domain"
    assert sql =~ "arrayExists(x -> NOT has(b.ctl_subdomains, x), c.subs)"
    # Both join sides are bounded to the window's sighted domains, never the whole table.
    assert sql =~ ~r/SELECT domain, ctl_subdomains FROM businesses\s+WHERE domain IN \(SELECT domain FROM ctl_log WHERE seen_at >= toDateTime\(1700000000\)/
    assert Compact.sightings_with_new_hosts_sql(1_700_000_000) |> String.contains?("seen_at <") == false
  end

  test "the incremental fold recompiles those businesses in the same pass" do
    sql = Compact.fold_select_sql(1_700_000_000, 1_700_003_600)
    [before_touched | _] = String.split(sql, "AS _touched")
    assert before_touched =~ "arrayExists(x -> NOT has(b.ctl_subdomains, x), c.subs)",
           "the sightings leg must be part of the domain set that defines _touched"
    # The rebuild form has no window and no domain set: nothing to add there.
    refute Compact.fold_select_sql(0) =~ "NOT has(b.ctl_subdomains"
  end

  test "a repeated sighting adds no domain: only NEW hosts recompile" do
    # Pure shape check: the predicate is on hosts absent from the stored set,
    # so a renewal that repeats the same hosts yields an empty array and is dropped.
    sql = Compact.sightings_with_new_hosts_sql(1)
    assert sql =~ "NOT has(b.ctl_subdomains, x)"
    refute sql =~ "arrayExists(x -> has("
  end
end
