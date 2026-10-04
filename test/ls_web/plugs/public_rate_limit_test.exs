defmodule LSWeb.Plugs.PublicRateLimitTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias LSWeb.Plugs.PublicRateLimit

  @moduledoc """
  2026-10-04, 00:00 to 01:00 UTC: one client fetched public store pages at
  130 to 1,000 a minute; each is a 77 MB point read, ClickHouse ran at
  350% CPU, load hit 20, the compaction and the backup dump failed on the
  memory ceiling. A public page gets a per-client ceiling.
  """

  defp window, do: System.unique_integer([:positive]) + 1_000_000

  test "the sixty-first request in a minute from one address is refused, the first sixty pass" do
    w = window()
    ip = "203.0.113.#{rem(w, 250)}"
    for _ <- 1..60, do: assert(PublicRateLimit.hit(ip, 60, w) == :ok)
    assert PublicRateLimit.hit(ip, 60, w) == :over
    assert PublicRateLimit.hit(ip, 60, w + 1) == :ok
  end

  test "addresses are counted apart" do
    w = window()
    for _ <- 1..60, do: PublicRateLimit.hit("198.51.100.1", 60, w)
    assert PublicRateLimit.hit("198.51.100.1", 60, w) == :over
    assert PublicRateLimit.hit("198.51.100.2", 60, w) == :ok
  end

  test "the client is Cloudflare's address first, then the first forwarded hop, then the socket" do
    conn = conn(:get, "/website/x") |> put_req_header("cf-connecting-ip", "192.0.2.9") |> put_req_header("x-forwarded-for", "10.0.0.1, 10.0.0.2")
    assert PublicRateLimit.client_ip(conn) == "192.0.2.9"
    conn = conn(:get, "/website/x") |> put_req_header("x-forwarded-for", "10.0.0.1, 10.0.0.2")
    assert PublicRateLimit.client_ip(conn) == "10.0.0.1"
    assert PublicRateLimit.client_ip(conn(:get, "/website/x")) == "127.0.0.1"
  end

  test "over the limit the plug answers 429 with Retry-After and halts" do
    ip = "192.0.2.#{rem(window(), 250)}"
    w = div(System.system_time(:second), 60)
    for _ <- 1..PublicRateLimit.per_min(), do: PublicRateLimit.hit(ip, PublicRateLimit.per_min(), w)

    conn = conn(:get, "/website/some-shop") |> put_req_header("cf-connecting-ip", ip) |> PublicRateLimit.call([])
    assert conn.halted
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["60"]
  end

  test "under the limit the plug does nothing" do
    conn = conn(:get, "/pricing") |> put_req_header("cf-connecting-ip", "192.0.2.250") |> PublicRateLimit.call([])
    refute conn.halted
  end

  test "the box's own loopback requests are never counted: the watchdog probes every minute" do
    assert PublicRateLimit.local?(conn(:get, "/"))
    refute PublicRateLimit.local?(conn(:get, "/") |> put_req_header("cf-connecting-ip", "192.0.2.1"))
    refute PublicRateLimit.local?(%{conn(:get, "/") | remote_ip: {203, 0, 113, 7}})
    for _ <- 1..200, do: refute(PublicRateLimit.call(conn(:get, "/website/x"), []).halted)
  end

  test "the public pipeline carries the limiter" do
    assert File.read!("lib/ls_web/router.ex") =~ "plug LSWeb.Plugs.PublicRateLimit"
  end
end
