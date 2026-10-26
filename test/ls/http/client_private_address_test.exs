defmodule LS.HTTP.ClientPrivateAddressTest do
  @moduledoc """
  2026-10-26: the client connected by hostname, so the address it had
  validated for rate limiting played no part in where the socket went, and
  a redirect to another host connected by name with no check and no
  limiter. Now the socket goes to the validated address, a non-public
  address is refused before any request, and a cross-host hop is resolved,
  checked and paced like a first contact.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.Client

  test "a private, loopback or link-local address is refused before any request is made" do
    for ip <- ~w(10.0.0.156 127.0.0.1 169.254.169.254 192.168.0.10 100.64.1.1) do
      assert {:error, "private_address", :private_address} = Client.fetch("becauseweponder.us", ip)
      assert {:error, "private_address", :private_address} = Client.fetch("becauseweponder.us", ip, path: "/robots.txt")
    end
  end

  test "no address is still no fetch" do
    assert {:error, "no_ip", :no_ip} = Client.fetch("example.com", nil)
  end

  describe "hop_address/4" do
    test "a redirect on the same host keeps the address already validated and resolves nothing" do
      resolve = fn _ -> flunk("must not resolve the same host") end
      assert {:ok, "104.21.68.88"} = Client.hop_address("acme.com", "104.21.68.88", "acme.com", resolve)
    end

    test "a redirect to a host that resolves only to a private address is not followed" do
      resolve = fn "internal.acme.com" -> {:ok, %{a: ["10.0.0.1", "127.0.0.1"]}} end
      assert :stop = Client.hop_address("acme.com", "104.21.68.88", "internal.acme.com", resolve)
    end

    test "a redirect to a host with a public address follows to that address, skipping private ones" do
      resolve = fn "www.acme.com" -> {:ok, %{a: ["10.0.0.5", "203.0.113.1", "151.101.1.1"]}} end
      assert {:ok, "151.101.1.1"} = Client.hop_address("acme.com", "104.21.68.88", "www.acme.com", resolve)
    end

    test "a host that does not resolve, or a resolver that fails, stops the hop" do
      assert :stop = Client.hop_address("acme.com", "1.1.1.1", "gone.acme.com", fn _ -> {:error, :nxdomain} end)
      assert :stop = Client.hop_address("acme.com", "1.1.1.1", "gone.acme.com", fn _ -> {:ok, %{a: []}} end)
      assert :stop = Client.hop_address("acme.com", "1.1.1.1", "gone.acme.com", fn _ -> :garbage end)
    end
  end
end
