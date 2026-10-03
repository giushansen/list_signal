defmodule LS.MetricsDeadChecksTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-03, within the hour of the first liveness pass: the master's
  18K dead-check rows (worker 'master', status NULL, error dns_unresolved)
  read as a worker whose every resolved name fails HTTP, and as a jump in
  the fleet's HTTP error rate. Two alerts for data that is correct. A dead
  check is a check, not a fetch, and no fleet metric counts it.
  """

  test "per-worker and known-worker queries skip the master's dead checks" do
    assert LS.Metrics.per_worker_sql(6) =~ "AND worker != 'master'"
    assert LS.Metrics.known_workers_sql(3) =~ "AND worker != 'master'"
    assert LS.Metrics.fleet_rows() == "worker != 'master'"
  end

  test "the HTTP errors data check does not count a dead check as an error" do
    {_, cond_sql} = List.keyfind(LS.DataCheck.error_metrics(), "HTTP errors", 0)
    assert cond_sql =~ "http_error != 'dns_unresolved'"
  end
end
