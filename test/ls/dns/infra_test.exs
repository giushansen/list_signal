defmodule LS.DNS.InfraTest do
  use ExUnit.Case, async: true

  alias LS.DNS.Infra

  @moduledoc """
  PTR and Microsoft enterprise records (2026-09-06): size signals for the
  revenue estimator that no web page shows. Network lookups are not tested
  here; the cache, the reverse-name arithmetic and the classification are.
  """

  test "reverse names are built right" do
    assert Infra.reverse_name({45, 63, 7, 58}) == ~c"58.7.63.45.in-addr.arpa"
  end

  test "a cached PTR is served without a lookup and survives hostile input" do
    Infra.seed_ptr("203.0.113.9", "mail.acme.com")
    assert Infra.ptr("203.0.113.9") == "mail.acme.com"
    assert Infra.ptr(nil) == ""
    assert Infra.ptr("") == ""
    assert Infra.ptr("not-an-ip") == ""
  end

  test "ptr_kind tells branded from shared hosting" do
    assert Infra.ptr_kind("mail.acme.com", "acme.com") == :branded
    assert Infra.ptr_kind("acme-web-01.rack.net", "acme.com") == :branded
    assert Infra.ptr_kind("srv-4711.hostingco.net", "acme.com") == :shared
    assert Infra.ptr_kind("ec2-1-2-3-4.compute.amazonaws.com", "acme.com") == :shared
    assert Infra.ptr_kind("", "acme.com") == :unknown
    assert Infra.ptr_kind("x.y", "ab.com") == :unknown, "a 2-letter label cannot claim a match"
    assert Infra.ptr_kind(nil, nil) == :unknown
  end

  test "no MX means no Microsoft lookups and empty flags" do
    assert Infra.lookup("example.com", nil, []) == %{ptr: "", ms_enterprise: ""}
    assert Infra.lookup(nil, nil, nil) == %{ptr: "", ms_enterprise: ""}
  end
end
