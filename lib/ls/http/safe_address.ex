defmodule LS.HTTP.SafeAddress do
  @moduledoc """
  Is an address one the crawler may connect to? Pure.

  Found 2026-10-26: `becauseweponder.us` resolved to `10.0.0.156`, a worker
  connected to it over the WireGuard mesh, and the master's own homepage
  (title, h1, `will@listsignal.com`) was written into that business's row.
  53 businesses carried our page; 5,048 had a private or loopback address
  on record. Anyone can point a name at `10.0.0.x` or `127.0.0.1` and have
  the crawler read whatever listens on our internal hosts, or on the
  worker itself, into the product.

  The rule is applied in three places, each on its own: the worker picks
  only a public address from DNS (`first_public/1`), `LS.HTTP.Client`
  refuses a non-public address and connects to the address it validated
  (never to the hostname, so a second resolution cannot swap it), and
  every redirect hop to another host is resolved and checked again.

  Refused: RFC 1918, loopback, link-local, carrier-grade NAT, the
  documentation and benchmark ranges, "this host" (0/8), multicast and
  reserved; for IPv6 the unspecified and loopback addresses, unique local,
  link-local, multicast, documentation, and any IPv4 carried inside an
  IPv6 address (v4-mapped, NAT64, 6to4), judged by the IPv4 rules.
  """

  @doc "True for an address string the crawler may connect to. Strict parsing: \"1.2.3\" is not an address here."
  @spec public?(term()) :: boolean()
  def public?(ip) when is_binary(ip) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(ip))) do
      {:ok, tuple} -> public_tuple?(tuple)
      _ -> false
    end
  end

  def public?(_), do: false

  @doc "The first public address in a list, or nil. Accepts nil and non-lists."
  @spec first_public(term()) :: String.t() | nil
  def first_public(ips), do: ips |> List.wrap() |> Enum.find(&public?/1)

  @doc false
  def public_tuple?({a, b, c, _d}) do
    cond do
      a == 0 -> false
      a == 10 -> false
      a == 100 and b in 64..127 -> false
      a == 127 -> false
      a == 169 and b == 254 -> false
      a == 172 and b in 16..31 -> false
      a == 192 and b == 0 and c in [0, 2] -> false
      a == 192 and b == 88 and c == 99 -> false
      a == 192 and b == 168 -> false
      a == 198 and b in [18, 19] -> false
      a == 198 and b == 51 and c == 100 -> false
      a == 203 and b == 0 and c == 113 -> false
      a >= 224 -> false
      true -> true
    end
  end

  # IPv4 carried inside IPv6: judged as IPv4.
  def public_tuple?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: public_tuple?(v4(hi, lo))
  def public_tuple?({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: public_tuple?(v4(hi, lo))
  def public_tuple?({0x2002, hi, lo, _, _, _, _, _}), do: public_tuple?(v4(hi, lo))

  def public_tuple?({w0, w1, _, _, _, _, _, _} = v6) do
    cond do
      v6 == {0, 0, 0, 0, 0, 0, 0, 0} -> false
      v6 == {0, 0, 0, 0, 0, 0, 0, 1} -> false
      Bitwise.band(w0, 0xFE00) == 0xFC00 -> false
      Bitwise.band(w0, 0xFFC0) == 0xFE80 -> false
      Bitwise.band(w0, 0xFF00) == 0xFF00 -> false
      w0 == 0x2001 and w1 == 0x0DB8 -> false
      true -> true
    end
  end

  def public_tuple?(_), do: false

  defp v4(hi, lo), do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}
end
