defmodule LS.Cluster.InserterGuardTest do
  @moduledoc """
  Guard against the failure mode that ran undetected from 2026-07-04 to
  2026-07-25: the h1 worker's OS resolver broke, so DNS enrichment kept working
  (it pins Unbound explicitly) while HTTP, BGP and RDAP silently returned
  nothing. h1 kept claiming batches and wrote ~56M hollow rows, which — because
  `domains_current` is a ReplacingMergeTree(enriched_at) — REPLACED good data
  for ~933K domains.

  The guard must quarantine that worker, and must never fire on a healthy one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LS.Cluster.Inserter

  @healthy_worker "worker_lsny1@10.0.0.2"
  @sick_worker "worker_lsh1@10.0.0.7"

  # Mirrors what merge_row/8 produces for a fully-enriched domain.
  defp healthy_row(worker, n) do
    %{worker: worker, domain: "d#{n}.com", dns_a: "104.18.0.#{rem(n, 254)}",
      http_status: 200, bgp_asn_number: "13335", rdap_registrar: "MarkMonitor Inc.",
      enriched_at: "2026-07-26 04:00:00"}
  end

  # What h1 produced: DNS resolved, everything downstream empty.
  defp hollow_row(worker, n) do
    %{worker: worker, domain: "d#{n}.com", dns_a: "104.18.0.#{rem(n, 254)}",
      http_status: nil, bgp_asn_number: "", rdap_registrar: "",
      http_error: "transport::nxdomain", enriched_at: "2026-07-26 04:00:00"}
  end

  # Domains that never resolved are not the guard's business — they're a normal
  # ~6% of every worker's output and carry no enrichment by definition.
  defp unresolved_row(worker, n) do
    %{worker: worker, domain: "d#{n}.com", dns_a: "", http_status: nil,
      bgp_asn_number: "", rdap_registrar: "", enriched_at: "2026-07-26 04:00:00"}
  end

  setup do
    # Isolated instance — the supervised singleton is already running and we
    # must not share its buffer or guard state between tests.
    pid = start_supervised!({Inserter, name: :guard_test_inserter})
    %{ins: pid}
  end

  defp feed(rows),
    do: Enum.each(Enum.chunk_every(rows, 500), &Inserter.insert(:guard_test_inserter, &1))

  defp settle do
    # insert/2 is a cast; worker_health/1 is a call on the same process, so it
    # naturally drains the mailbox ahead of it.
    Inserter.worker_health(:guard_test_inserter)
  end

  defp health, do: Inserter.worker_health(:guard_test_inserter)
  defp release(w), do: Inserter.release_worker(:guard_test_inserter, w)

  test "quarantines a worker whose enrichment collapsed while DNS still works" do
    log =
      capture_log(fn ->
        feed(Enum.map(1..3_000, &hollow_row(@sick_worker, &1)))
        settle()
      end)

    assert log =~ "QUARANTINING #{@sick_worker}"
    health = health()
    assert health[@sick_worker].quarantined
  end

  test "drops rows from a quarantined worker so they cannot overwrite good data" do
    capture_log(fn ->
      feed(Enum.map(1..3_000, &hollow_row(@sick_worker, &1)))
      settle()
    end)

    capture_log(fn ->
      feed(Enum.map(3_001..5_000, &hollow_row(@sick_worker, &1)))
      settle()
    end)

    assert health()[@sick_worker].dropped >= 2_000
  end

  test "never quarantines a healthy worker" do
    log =
      capture_log(fn ->
        feed(Enum.map(1..4_500, &healthy_row(@healthy_worker, &1)))
        settle()
      end)

    refute log =~ "QUARANTINING"
    health = health()
    refute health[@healthy_worker].quarantined
  end

  test "tolerates the real-world mix: ~6% unresolved and some failed crawls" do
    rows =
      Enum.map(1..4_500, fn n ->
        cond do
          rem(n, 16) == 0 -> unresolved_row(@healthy_worker, n)
          # a crawl that errored but still got BGP — the common healthy case
          rem(n, 3) == 0 ->
            %{healthy_row(@healthy_worker, n) | http_status: nil, rdap_registrar: ""}

          true -> healthy_row(@healthy_worker, n)
        end
      end)

    log = capture_log(fn -> feed(rows); settle() end)

    refute log =~ "QUARANTINING"
    refute health()[@healthy_worker].quarantined
  end

  test "one sick worker does not quarantine the healthy ones alongside it" do
    rows =
      Enum.flat_map(1..3_000, fn n ->
        [hollow_row(@sick_worker, n), healthy_row(@healthy_worker, n)]
      end)

    capture_log(fn -> feed(rows); settle() end)

    health = health()
    assert health[@sick_worker].quarantined
    refute health[@healthy_worker].quarantined
  end

  test "release_worker/1 clears a quarantine and resumes accepting rows" do
    capture_log(fn ->
      feed(Enum.map(1..3_000, &hollow_row(@sick_worker, &1)))
      settle()
    end)

    assert health()[@sick_worker].quarantined

    capture_log(fn -> assert :ok = release(@sick_worker) end)

    health = health()
    refute health[@sick_worker].quarantined
    assert health[@sick_worker].dropped == 0

    # a now-healthy node is accepted again
    capture_log(fn ->
      feed(Enum.map(1..3_000, &healthy_row(@sick_worker, &1)))
      settle()
    end)

    refute health()[@sick_worker].quarantined
  end

  test "release_worker/1 on an unknown worker is an error, not a crash" do
    assert {:error, :unknown_worker} = release("worker_nope@10.0.0.99")
  end
end
