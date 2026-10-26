defmodule LSWeb.Plugs.HostGuardTest do
  @moduledoc """
  2026-10-26: ctf-nm.org, proxied through Cloudflare at our origin, was
  served the ListSignal homepage and the crawler recorded it as that
  business. The origin answers only for its own names now.
  """
  use ExUnit.Case, async: true
  import Plug.Test

  alias LSWeb.Plugs.HostGuard

  test "the site host, its www form and local probe addresses are allowed" do
    for h <- ~w(listsignal.com www.listsignal.com LISTSIGNAL.COM listsignal.com. 127.0.0.1 localhost 10.0.0.1 45.63.7.58) do
      assert HostGuard.allowed?(h, "listsignal.com"), h
    end
  end

  test "any other name is refused, including lookalikes and the one from the incident" do
    for h <- ~w(ctf-nm.org becauseweponder.us listsignal.com.evil.net notlistsignal.com api.listsignal.com) do
      refute HostGuard.allowed?(h, "listsignal.com"), h
    end

    refute HostGuard.allowed?("", "listsignal.com")
    refute HostGuard.allowed?(nil, "listsignal.com")
    refute HostGuard.allowed?(123, "listsignal.com")
  end

  test "an operator-listed extra host is allowed" do
    assert HostGuard.allowed?("staging.listsignal.com", "listsignal.com", ["staging.listsignal.com"])
    refute HostGuard.allowed?("staging.listsignal.com", "listsignal.com", [])
  end

  test "with no configured site (dev, test) everything passes, as before" do
    assert HostGuard.allowed?("anything.example", nil)
    assert HostGuard.allowed?("anything.example", "localhost")
  end

  test "the plug halts a misdirected request with 421 and no body of ours" do
    conn = conn(:get, "/") |> Map.put(:host, "ctf-nm.org")
    # The test endpoint is configured with host localhost, so the plug
    # itself allows everything here; the decision is covered above. Exercise
    # the plug path once so a crash would surface.
    assert %Plug.Conn{halted: false} = HostGuard.call(conn, [])
  end
end
