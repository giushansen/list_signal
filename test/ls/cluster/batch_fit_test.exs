defmodule LS.Cluster.BatchFitTest do
  @moduledoc """
  2026-10-24: a third of all rows the fleet wrote had no HTTP status and no
  error. Every batch carried 290 to 622 HTTP candidates against a budget
  share of 60 slots a minute, the stage deadline counted 1.5 slots per
  candidate while a first contact costs about 2.1 (robots.txt is never
  cached at first contact), so 100 to 235 candidates per batch were cut in
  flight and written as hollow rows. Those rows advanced
  http_last_checked_at (8,175 of 27,827 tier A businesses touched that day
  got nothing else) and marked the daily bloom. The batch now fetches only
  what its budget share can finish, hands the rest back, and a cut
  candidate gets no row.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  test "the stage bound counts 3.4 slots per candidate (homepage 2.2 plus secondary pages 1.2), never below two minutes" do
    # 2026-10-27: the address page joined the plan and the old 2.2 cut 124
    # of 143 candidates per batch. 350 candidates at 140/min: 350 * 3.4 *
    # 60000 / 140 = 510 s, plus a minute of slack.
    assert WorkerAgent.http_stage_timeout(350, 140) == 570_000
    assert WorkerAgent.http_stage_timeout(50, 140) == 132_857
    assert WorkerAgent.http_stage_timeout(123, 60) == 478_200
  end

  test "the candidate cap is what the batch's budget share finishes inside the window" do
    # 60 slots/min for 7 minutes is 420 slots; at 3.4 each that is 123 candidates.
    assert WorkerAgent.http_candidate_cap(60, 420_000) == 123
    assert WorkerAgent.http_candidate_cap(140, 420_000) == 288
    # A tiny share still fetches something rather than stalling.
    assert WorkerAgent.http_candidate_cap(1, 420_000) == 20
    assert WorkerAgent.http_candidate_cap(0, 420_000) == 20
  end

  test "a batch sized to the cap always ends inside the master's in-flight timeout" do
    # Otherwise the master requeues it and a second node fetches the same sites.
    for per_min <- [30, 55, 60, 70, 110, 140] do
      cap = WorkerAgent.http_candidate_cap(per_min)
      worst_http_ms = WorkerAgent.http_stage_timeout(cap, per_min)
      dns_and_merge_ms = 30_000 + 60_000
      assert worst_http_ms + dns_and_merge_ms < LS.Cluster.WorkQueue.batch_timeout_ms(),
             "share #{per_min}/min: cap #{cap} worst case #{worst_http_ms} ms does not fit"
    end
  end

  test "candidates past the cap are surplus, in order, and nothing is lost" do
    cands = for i <- 1..7, do: {"d#{i}.com", "203.0.113.#{i}"}
    {take, surplus} = WorkerAgent.split_candidates(cands, 3)
    assert take == Enum.take(cands, 3)
    assert surplus == Enum.drop(cands, 3)
    assert WorkerAgent.split_candidates(cands, 100) == {cands, []}
    assert WorkerAgent.split_candidates([], 3) == {[], []}
  end

  test "a candidate the stage returned nothing for is unfetched, an errored one is not" do
    cands = [{"ok.com", "1.1.1.1"}, {"err.com", "1.1.1.2"}, {"cut.com", "1.1.1.3"}]
    res = %{"ok.com" => %{http_status: 200}, "err.com" => %{http_status: nil, http_error: "transport::timeout"}}
    assert WorkerAgent.unfetched(cands, res) == [{"cut.com", "1.1.1.3"}]
    assert WorkerAgent.unfetched(cands, %{}) == cands
    assert WorkerAgent.unfetched([], res) == []
  end

  test "a cut candidate writes no row: only fetched candidates reach rows_to_write" do
    domains = [%{ctl_domain: "ok.com"}, %{ctl_domain: "cut.com"}, %{ctl_domain: "err.com"}]
    dns = %{"ok.com" => %{dns: %{}}, "cut.com" => %{dns: %{}}, "err.com" => %{dns: %{}}}
    cands = [{"ok.com", "1.1.1.1"}, {"cut.com", "1.1.1.3"}, {"err.com", "1.1.1.2"}]
    res = %{"ok.com" => %{http_status: 200}, "err.com" => %{http_status: nil, http_error: "transport::closed"}}
    fetched = cands -- WorkerAgent.unfetched(cands, res)
    rows = WorkerAgent.rows_to_write(domains, dns, fetched) |> Enum.map(& &1.ctl_domain)
    assert rows == ["ok.com", "err.com"]
    refute "cut.com" in rows
  end

  test "the dequeue asks for enough names to reach the cap at the learned pass rate, within bounds" do
    assert WorkerAgent.dequeue_size(190, 0.4, 1000) == 475
    assert WorkerAgent.dequeue_size(190, 0.95, 1000) == 200
    assert WorkerAgent.dequeue_size(123, 0.4, 1000) == 308
    # A pass rate that would ask for the whole queue is bounded by the configured batch size.
    assert WorkerAgent.dequeue_size(190, 0.05, 1000) == 1000
    # A pass rate above 1 is nonsense: clamp, and never ask for fewer than 100.
    assert WorkerAgent.dequeue_size(50, 3.0, 1000) == 100
    assert WorkerAgent.dequeue_size(190, 0.4, 300) == 300
  end

  test "the learned pass rate is clamped and survives an empty batch" do
    assert WorkerAgent.candidate_ratio(380, 1000) == 0.38
    assert WorkerAgent.candidate_ratio(0, 1000) == 0.1
    assert WorkerAgent.candidate_ratio(2000, 1000) == 1.0
    assert WorkerAgent.candidate_ratio(0, 0) == 0.4
  end
end
