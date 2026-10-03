defmodule LS.Recrawl.LivenessResolverTest do
  use ExUnit.Case, async: true

  alias LS.Recrawl.Liveness

  @moduledoc """
  2026-10-03, first liveness pass on the master: 12,500 names through
  `LS.DNS.Resolver.lookup/1` (five record types, three 8 s retries each)
  had not finished after 13 minutes. One A query per name now, and a
  timeout is never a death: the h1 split-brain of 2026-08 came from a
  resolver that could not answer, not from names that did not exist.
  """

  test "an unknown answer is neither dead nor alive, and the name goes to a worker" do
    refute Liveness.dead?({:unknown, :timeout})
    refute Liveness.alive?({:unknown, :timeout})
    due = [{"flaky.example", "a"}, {"dead.example", "a"}]

    resolve = fn
      "flaky.example" -> {:unknown, :timeout}
      "dead.example" -> {:ok, %{a: []}}
      _anchor -> {:ok, %{a: ["203.0.113.1"]}}
    end

    assert {:ok, [{"flaky.example", "a"}], [{"dead.example", "a"}]} = Liveness.partition(due, resolve)
  end

  test "an anchor that only times out makes the run suspect: a positive answer is required" do
    resolve = fn
      "shopify.com" -> {:unknown, :timeout}
      _ -> {:ok, %{a: ["203.0.113.1"]}}
    end

    assert {:error, :resolver_suspect} = Liveness.partition([{"x.example", "a"}], resolve)
  end

  test "dead names are recorded in URL-sized chunks" do
    # 10,213 names in one statement: "HTML Form Exception: Field value too
    # long" and nothing recorded (first pass, 17:29 UTC).
    assert Liveness.chunk_size() <= 500
  end

  test "the single-query resolver answers in the resolver's own vocabulary" do
    # No network in the suite: a name under .invalid never resolves, and
    # the resolver may answer nxdomain or an error depending on the host.
    assert LS.DNS.Resolver.a_status("nothing.invalid", 1_500) in [:nxdomain, {:error, :timeout}, {:error, :exception}] or
             match?({:error, _}, LS.DNS.Resolver.a_status("nothing.invalid", 1_500))
  end
end
