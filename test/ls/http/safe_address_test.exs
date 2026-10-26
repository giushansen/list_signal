defmodule LS.HTTP.SafeAddressTest do
  @moduledoc """
  2026-10-26: becauseweponder.us resolved to 10.0.0.156 and a worker read the
  master's homepage into that business over the mesh (53 businesses carried
  our page, 5,048 had a private or loopback address on record). Every
  address the crawler connects to passes this rule first.
  """
  use ExUnit.Case, async: true

  alias LS.HTTP.SafeAddress

  test "the address that leaked our homepage, and every private IPv4 range, is refused" do
    for ip <- ~w(10.0.0.156 10.255.255.255 172.16.0.1 172.31.255.254 192.168.1.1 127.0.0.1 127.255.0.9
                 169.254.169.254 100.64.0.1 100.127.255.255 0.0.0.0 0.1.2.3 192.0.0.8 192.0.2.44 198.18.0.1
                 198.19.255.255 198.51.100.7 203.0.113.9 224.0.0.1 239.255.255.255 240.0.0.1 255.255.255.255) do
      refute SafeAddress.public?(ip), ip
    end
  end

  test "ordinary public IPv4 addresses pass, including the neighbours of each refused range" do
    for ip <- ~w(8.8.8.8 1.1.1.1 172.15.255.255 172.32.0.1 100.63.255.255 100.128.0.0 192.0.1.1 192.0.3.1
                 198.17.255.255 198.20.0.1 198.51.101.1 203.0.112.1 223.255.255.255 45.63.7.58 104.21.68.88) do
      assert SafeAddress.public?(ip), ip
    end
  end

  test "IPv6: unspecified, loopback, unique local, link-local, multicast and documentation are refused" do
    for ip <- ~w(:: ::1 fc00::1 fdff:ffff::1 fe80::1 febf::1 ff02::1 2001:db8::1) do
      refute SafeAddress.public?(ip), ip
    end

    assert SafeAddress.public?("2606:4700:4700::1111")
    assert SafeAddress.public?("2a00:1450:4001:80b::200e")
  end

  test "an IPv4 hidden inside an IPv6 address is judged as IPv4" do
    refute SafeAddress.public?("::ffff:10.0.0.156")
    refute SafeAddress.public?("::ffff:127.0.0.1")
    refute SafeAddress.public?("64:ff9b::a00:9c")
    refute SafeAddress.public?("2002:a00:9c::")
    assert SafeAddress.public?("::ffff:8.8.8.8")
    assert SafeAddress.public?("64:ff9b::808:808")
  end

  test "hostile input is never public" do
    for v <- ["", " ", "localhost", "10.0.0.1/8", "1.2.3", "1.2.3.4.5", "not an ip", nil, 42, :atom, %{}, [1, 2]] do
      refute SafeAddress.public?(v), inspect(v)
    end
  end

  test "first_public skips private addresses and copes with nil, empty and junk lists" do
    assert SafeAddress.first_public(["10.0.0.156", "127.0.0.1", "104.21.68.88", "1.1.1.1"]) == "104.21.68.88"
    assert SafeAddress.first_public(["10.0.0.156"]) == nil
    assert SafeAddress.first_public([]) == nil
    assert SafeAddress.first_public(nil) == nil
    assert SafeAddress.first_public("8.8.8.8") == "8.8.8.8"
    assert SafeAddress.first_public([nil, "", "x", "9.9.9.9"]) == "9.9.9.9"
  end
end
