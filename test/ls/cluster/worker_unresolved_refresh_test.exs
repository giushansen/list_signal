defmodule LS.Cluster.WorkerUnresolvedRefreshTest do
  @moduledoc """
  2026-10-26: the tier A lane admitted 148K names a day and 60K rows landed.
  The oldest due businesses, last fetched in June, answered SERVFAIL on the
  master (liveness lets that through) and timed out on the worker, which
  dropped them with no row and no count. Their http_last_checked_at never
  moved, so the same ~2,000 names were re-admitted every 30 minutes and took
  45% of every tick. A refresh item that resolves to nothing now has its
  check recorded on the master, like a dead name found by liveness.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  @refresh %{ctl_domain: "zombie.example", source: :recrawl, tier: "a", prev_simhash: 0}
  @refresh_ok %{ctl_domain: "alive.example", source: :recrawl, tier: "a", prev_simhash: 0}
  @ctl %{ctl_domain: "newname.example", source: :ctl}
  @refresh_timeout %{ctl_domain: "slow.example", source: :recrawl, tier: "b", prev_simhash: 0}

  test "a refresh item with no address and no candidate is reported; a new name is not" do
    dns = %{
      "zombie.example" => %{dns: %{a: [], aaaa: [], mx: [], txt: [], cname: []}},
      "alive.example" => %{dns: %{a: ["203.0.113.9"]}},
      "newname.example" => %{dns: %{a: []}}
      # slow.example timed out: not in dns_results at all
    }

    cands = [{"alive.example", "203.0.113.9"}]
    assert WorkerAgent.unresolved_refresh([@refresh, @refresh_ok, @ctl, @refresh_timeout], dns, cands) == ["zombie.example", "slow.example"]
  end

  test "a refresh item that became a candidate is never reported, even with an odd DNS shape" do
    dns = %{"alive.example" => %{dns: %{a: nil}}}
    assert WorkerAgent.unresolved_refresh([@refresh_ok], dns, [{"alive.example", "203.0.113.9"}]) == []
  end

  test "hostile items never crash the batch" do
    items = [%{source: :recrawl}, %{ctl_domain: "", source: :recrawl}, %{ctl_domain: nil, source: :recrawl}, %{}, @refresh]
    assert WorkerAgent.unresolved_refresh(items, %{}, []) == ["zombie.example"]
    assert WorkerAgent.unresolved_refresh([], %{}, []) == []
  end

  test "the master records the check off the queue process and tolerates garbage" do
    assert LS.Cluster.WorkQueue.record_unresolved_refresh([]) == :ok
    assert LS.Cluster.WorkQueue.record_unresolved_refresh(["", nil, 42]) == :ok
    assert LS.Cluster.WorkQueue.record_unresolved_refresh(:nope) == :ok
    # With no ClickHouse the task logs and returns; the queue keeps working.
    assert LS.Cluster.WorkQueue.remember_skipped(%{unresolved_refresh: ["zombie.example"], dormant: [], soft: []}) == :ok
  end
end
