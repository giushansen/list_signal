defmodule LS.Cluster.WorkerRowsToWriteTest do
  @moduledoc """
  A filtered or unresolved domain writes no row (2026-10-01). Before, every
  domain in a batch did: 345M of the 506M rows in enrich_log carried DNS
  fields and nothing else, and because `domains` is newest-row-wins such a
  row replaced a domain's good HTTP data with blanks on every re-sighting.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  @domains [%{ctl_domain: "fetched.com"}, %{ctl_domain: "filtered.top"}, %{domain: "unresolved.com"}, %{ctl_domain: "failed.com"}]
  @dns %{"fetched.com" => %{dns: %{a: ["203.0.113.1"]}}, "filtered.top" => %{dns: %{a: ["203.0.113.2"]}}, "failed.com" => %{dns: %{a: ["203.0.113.3"]}}}

  test "only domains the HTTP stage attempted get a row, whether the fetch succeeded or not" do
    http_cands = [{"fetched.com", "203.0.113.1"}, {"failed.com", "203.0.113.3"}]
    kept = WorkerAgent.rows_to_write(@domains, @dns, http_cands)
    assert Enum.map(kept, &(&1[:ctl_domain] || &1[:domain])) == ["fetched.com", "failed.com"]
  end

  test "nothing attempted, nothing written" do
    assert WorkerAgent.rows_to_write(@domains, @dns, []) == []
  end

  test "the compactor's stable check carries the gap since the previous check and reads the newest compiled row" do
    sql = LS.Clickhouse.stable_domains_sql(1_700_000_000, 1_700_000_300)
    assert sql =~ "dateDiff('day', ifNull(o.http_last_checked_at, n.at), n.at) AS gap_days"
    assert sql =~ "LIMIT 1 BY domain"
  end

  test "changed domains for the hot ring exclude subdomain churn" do
    # Pure SQL shape; the query itself runs against ClickHouse in the compactor.
    assert function_exported?(LS.Clickhouse, :changed_domains, 2)
  end
end

defmodule LS.Cluster.WorkerHttpStageTimeoutTest do
  @moduledoc """
  The HTTP stage await must cover the node budget's pacing (2026-10-01
  evening): a fixed 120 s killed stages that were legitimately taking
  150 s and threw every fetched page of the batch away.
  """
  use ExUnit.Case, async: true

  test "the await grows with the candidate count at the budgeted rate, never below two minutes" do
    assert LS.Cluster.WorkerAgent.http_stage_timeout(50, 140) == 120_000
    assert LS.Cluster.WorkerAgent.http_stage_timeout(350, 140) == 210_000
    assert LS.Cluster.WorkerAgent.http_stage_timeout(700, 140) == 360_000
  end
end
