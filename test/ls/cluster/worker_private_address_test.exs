defmodule LS.Cluster.WorkerPrivateAddressTest do
  @moduledoc """
  2026-10-26: a refresh of a known business whose name now points only at a
  private address is a dead name for the product: no fetch, and its check
  recorded so it leaves the head of the due list rather than being
  re-admitted every tick.
  """
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  test "a refresh item resolving only to private addresses is reported as unresolved" do
    items = [
      %{ctl_domain: "becauseweponder.us", source: :recrawl, tier: "a"},
      %{ctl_domain: "mixed.example", source: :recrawl, tier: "a"},
      %{ctl_domain: "newprivate.example", source: :ctl}
    ]

    dns = %{
      "becauseweponder.us" => %{dns: %{a: ["10.0.0.156"]}},
      "mixed.example" => %{dns: %{a: ["10.0.0.1", "104.21.68.88"]}},
      "newprivate.example" => %{dns: %{a: ["127.0.0.1"]}}
    }

    # mixed.example has a public address and would be a candidate; the
    # candidate list is what the caller passes, so it is excluded here.
    assert WorkerAgent.unresolved_refresh(items, dns, [{"mixed.example", "104.21.68.88"}]) == ["becauseweponder.us"]
  end
end
