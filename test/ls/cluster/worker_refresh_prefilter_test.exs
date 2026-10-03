defmodule LS.Cluster.WorkerRefreshPrefilterTest do
  # Not async: setup_all reloads the TLD table that other filter tests read.
  use ExUnit.Case, async: false

  alias LS.Cluster.WorkerAgent

  @moduledoc """
  2026-10-03: the scheduler's refresh items went through the same name
  filter as a first contact. A known business without an MX record was
  soft-skipped on every refresh (28-35 days in the stable ring, then
  skipped again), so it was never checked again; a known .xyz business
  met the low-yield rule the same way. Membership was decided by an
  observed 2xx; the filter guards first contact only.
  """

  setup_all do
    LS.HTTP.DomainFilter.load_tlds()
    :ok
  end

  test "a refresh item is fetched whatever the name filter would say" do
    assert :crawl = WorkerAgent.prefetch_verdict("known-shop.xyz", "", "", "203.0.113.5", "ZeroSSL ECC DV SSL CA", true)
    assert :crawl = WorkerAgent.prefetch_verdict("a-b-c.com", "", "", "203.0.113.5", "", true)
  end

  test "a first contact keeps the full filter" do
    assert {:skip, :low_yield} = WorkerAgent.prefetch_verdict("known-shop.xyz", "mx.example", "v=spf1 -all", "203.0.113.5", "", false)
    assert {:skip, :no_mail} = WorkerAgent.prefetch_verdict("some-shop.com", "", "", "203.0.113.5", "", false)
    assert :crawl = WorkerAgent.prefetch_verdict("some-shop.com", "mx.example", "v=spf1 -all", "203.0.113.5", "R11", false)
  end

  test "a refresh item whose DNS fails on the worker still writes no row: the master records that check" do
    domains = [%{ctl_domain: "dead.example", source: :recrawl, tier: "a"}, %{ctl_domain: "live.example", source: :recrawl, tier: "a"}]
    dns = %{"live.example" => %{dns: %{a: ["203.0.113.1"]}}}
    kept = WorkerAgent.rows_to_write(domains, dns, [{"live.example", "203.0.113.1"}])
    assert Enum.map(kept, & &1[:ctl_domain]) == ["live.example"]
  end
end
