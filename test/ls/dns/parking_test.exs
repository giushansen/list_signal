defmodule LS.DNS.ParkingTest do
  @moduledoc """
  Parking nameservers mark junk (2026-10-01: 132K unflagged businesses on
  Sedo, Bodis, Dovendi). The one rule that must never regress: a hosting
  provider's default DNS is not parking. Hostinger's dns-parking.com fronts
  731K real businesses and was the first false positive found.
  """
  use ExUnit.Case, async: true

  alias LS.DNS.Parking

  test "parking operators are recognised from a list or a pipe string, case and dot insensitive" do
    assert Parking.parked_ns?(["NS1.SEDOPARKING.COM", "NS2.SEDOPARKING.COM"])
    assert Parking.parked_ns?("ns3.dovendi.eu.|ns1.dovendi.nl")
    assert Parking.parked_ns?(["ns1.thisdomain.forsale"])
  end

  test "hosting defaults that merely sound like parking are not parking" do
    refute Parking.parked_ns?(["ns1.dns-parking.com", "ns2.dns-parking.com"]), "Hostinger"
    refute Parking.parked_ns?(["dns1.registrar-servers.com"]), "Namecheap"
    refute Parking.parked_ns?(["ns1.dnsowl.com"]), "NameSilo"
    refute Parking.parked_ns?(["curitiba.ns.porkbun.com"])
    refute Parking.parked_ns?(["albert.ns.cloudflare.com"])
    refute Parking.parked_ns?("sedoparking.com.evil.example"), "suffix match only on the label boundary"
  end

  test "hostile input never raises" do
    refute Parking.parked_ns?(nil)
    refute Parking.parked_ns?("")
    refute Parking.parked_ns?([nil, 42, ""])
  end

  test "the SQL predicate and the Elixir rule share one list" do
    sql = Parking.sql("rdap_nameservers")
    for m <- Parking.markers(), do: assert(sql =~ "'#{m}'")
    refute sql =~ "dns-parking"
    assert sql =~ "endsWith(ns, concat('.', m))"
  end
end
