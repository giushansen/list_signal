defmodule LS.Cluster.InserterGuardAutoreleaseTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias LS.Cluster.Inserter

  @moduledoc """
  2026-09-26: dal1 tripped the quality guard on a poisoned BGP cache (89.97%
  against a 90% floor) and stayed quarantined for twelve hours, dropping
  265K rows that carried HTTP and RDAP data, because a quarantine could only
  be lifted by a human running release_worker/1. The guard now keeps
  scoring the rows it drops and releases a worker whose next full window is
  healthy again. A worker that stays hollow, the h1 failure of 2026-07
  (0.000 for 686 hours), is never released.
  """

  @worker "worker_lsdal1@10.0.0.10"

  defp healthy_row(n),
    do: %{worker: @worker, domain: "d#{n}.com", dns_a: "104.18.0.#{rem(n, 254)}", http_status: 200,
          bgp_asn_number: "13335", rdap_registrar: "MarkMonitor Inc.", enriched_at: "2026-09-26 04:00:00"}

  defp hollow_row(n),
    do: %{worker: @worker, domain: "d#{n}.com", dns_a: "104.18.0.#{rem(n, 254)}", http_status: nil,
          bgp_asn_number: "", rdap_registrar: "", enriched_at: "2026-09-26 04:00:00"}

  setup do
    pid = start_supervised!({Inserter, name: :autorelease_test_inserter})
    %{ins: pid}
  end

  defp feed(rows), do: Enum.each(Enum.chunk_every(rows, 500), &Inserter.insert(:autorelease_test_inserter, &1))
  defp health, do: Inserter.worker_health(:autorelease_test_inserter)

  test "a quarantined worker whose rows are healthy again is released by itself, keeping the dropped count" do
    capture_log(fn ->
      feed(Enum.map(1..3_000, &hollow_row/1))
      health()
    end)

    assert health()[@worker].quarantined

    log =
      capture_log(fn ->
        feed(Enum.map(1..3_000, &healthy_row/1))
        health()
      end)

    assert log =~ "AUTO-RELEASED"
    refute health()[@worker].quarantined
    assert health()[@worker].dropped > 0, "the rows dropped while quarantined stay on the record"
  end

  test "a worker that stays hollow is never released" do
    log =
      capture_log(fn ->
        feed(Enum.map(1..3_000, &hollow_row/1))
        health()
        feed(Enum.map(3_001..9_000, &hollow_row/1))
        health()
      end)

    refute log =~ "AUTO-RELEASED"
    assert health()[@worker].quarantined
    assert health()[@worker].dropped >= 6_000
  end

  test "a partial recovery below the floor stays quarantined" do
    capture_log(fn ->
      feed(Enum.map(1..3_000, &hollow_row/1))
      health()
    end)

    # 80% enriched: better than hollow, still under the 90% floor.
    rows = Enum.map(1..3_000, fn n -> if rem(n, 5) == 0, do: hollow_row(n), else: healthy_row(n) end)

    log =
      capture_log(fn ->
        feed(rows)
        health()
      end)

    refute log =~ "AUTO-RELEASED"
    assert health()[@worker].quarantined
  end
end
