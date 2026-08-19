defmodule LSWeb.Plugs.OverloadGuardTest do
  @moduledoc """
  The guard is the last line between a traffic spike and an outage.

  2026-08-19: a 300-concurrent burst grew the BEAM from 0.8G to 6.3G, crossed
  its cgroup limit, and the kernel stalled the VM — every in-flight request
  lost. Shedding the excess costs a few visitors a retry instead.
  """
  use LSWeb.ConnCase, async: false

  alias LSWeb.Plugs.OverloadGuard

  test "requests pass through under the ceiling and the counter unwinds" do
    before = OverloadGuard.in_flight()

    conn = get(build_conn(), "/pricing")
    assert conn.status == 200

    assert OverloadGuard.in_flight() == before,
           "in-flight count must return to baseline or the guard leaks toward permanent 503s"
  end

  test "over the ceiling it sheds with 503 and retry-after" do
    conn =
      build_conn()
      |> Map.put(:request_path, "/tech/klaviyo")
      |> OverloadGuard.call(0)

    assert conn.status == 503
    assert conn.halted, "a shed request must not reach the router"
    assert get_resp_header(conn, "retry-after") == ["2"]
  end

  test "assets are never shed" do
    # Static files are cheap; shedding them breaks the page for users who did
    # get through, for no memory saving.
    conn =
      build_conn()
      |> Map.put(:request_path, "/assets/app.css")
      |> OverloadGuard.call(0)

    refute conn.halted
  end

  test "the ceiling bounds request memory inside the BEAM's limit" do
    # 150 in flight x ~10-20MB per page assembly is ~2-3G, inside the 8G soft
    # limit with room for ETS and the Tranco/Majestic tables.
    assert OverloadGuard.max_in_flight() <= 200,
           "a ceiling above ~200 stops bounding memory usefully"
  end
end
