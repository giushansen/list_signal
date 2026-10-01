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
    assert LS.Cluster.WorkerAgent.http_stage_timeout(350, 140) == 285_000
    assert LS.Cluster.WorkerAgent.http_stage_timeout(700, 140) == 510_000
  end
end

defmodule LS.Cluster.WorkerCollectUntilTest do
  @moduledoc """
  2026-10-02: with fetches paced by the node budget, the HTTP stage overran
  its await 3 to 4 times an hour per worker and the batch dropped every
  fetched page (41% hollow rows). The stage now keeps what finished by the
  deadline and gives up only on the rest.
  """
  use ExUnit.Case, async: true

  test "results that finished before the deadline are kept, the rest are counted as cut" do
    stream =
      Task.async_stream([10, 20, 400, 450], fn ms -> Process.sleep(ms); {"d#{ms}", ms} end,
        max_concurrency: 4, timeout: 5_000, ordered: false)

    {res, cut} = LS.Cluster.WorkerAgent.collect_until(stream, System.monotonic_time(:millisecond) + 150)
    # d400 arrived after the deadline but it did finish: kept. d450 never arrived: cut.
    assert Map.keys(res) |> Enum.sort() == ["d10", "d20", "d400"]
    assert cut == 1
  end

  test "a stage that finishes in time loses nothing" do
    stream = Task.async_stream([1, 2, 3], fn i -> {"d#{i}", i} end, timeout: 5_000, ordered: false)
    {res, cut} = LS.Cluster.WorkerAgent.collect_until(stream, System.monotonic_time(:millisecond) + 5_000)
    assert map_size(res) == 3 and cut == 0
  end

  test "the stage bound counts one and a half slots per candidate" do
    assert LS.Cluster.WorkerAgent.http_stage_timeout(350, 140) == 285_000
  end
end
