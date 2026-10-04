defmodule LSWeb.WellKnownAcceptTest do
  @moduledoc """
  2026-10-04: the MCP registry's key fetcher sets its own Accept header.
  The proof route first shipped inside the `:public` pipeline, whose
  `plug :accepts, ["html"]` answered **406 Not Acceptable**, and the
  registry reported it as "failed to fetch public key", which reads like
  the domain was never proved at all. The route now sits in a pipeline
  with no content negotiation.

  Pinned separately from the body/format test so a future pipeline tidy-up
  cannot quietly reintroduce the 406.
  """
  use LSWeb.ConnCase, async: true

  @path "/.well-known/mcp-registry-auth"

  test "every Accept header a registry fetcher might send still gets the proof" do
    for accept <- [
          "*/*",
          "text/plain",
          "application/json",
          "text/plain; charset=utf-8",
          "application/octet-stream"
        ] do
      conn =
        build_conn()
        |> put_req_header("accept", accept)
        |> get(@path)

      assert conn.status == 200,
             "Accept: #{accept} returned #{conn.status}; the registry reads anything but 200 as an unproved domain"

      assert conn.resp_body == LSWeb.WellKnownController.proof()
    end
  end

  test "a request with no Accept header at all is served" do
    conn = build_conn() |> delete_req_header("accept") |> get(@path)
    assert conn.status == 200
  end
end
