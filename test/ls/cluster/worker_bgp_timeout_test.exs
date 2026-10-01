defmodule LS.Cluster.WorkerBgpTimeoutTest do
  @moduledoc """
  2026-10-01: whois.cymru.com port 43 was unreachable from the two Paris
  nodes; the BGP resolver's call timed out, the exit killed the batch task
  and the linked WorkerAgent with it, and par1/par2 restarted 84 and 74
  times in two hours completing nothing. A slow or dead resolver must cost
  the BGP fields only.
  """
  use ExUnit.Case, async: true

  defmodule SlowResolver do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}
    def handle_call({:lookup_batch, _ips}, _from, state) do
      Process.sleep(2_000)
      {:reply, {:ok, %{}}, state}
    end
  end

  test "a resolver that does not answer in time yields no BGP data and no crash" do
    {:ok, pid} = SlowResolver.start_link(nil)
    assert LS.Cluster.WorkerAgent.bgp_lookup(pid, ["203.0.113.1"], 100) == %{}
    assert Process.alive?(self())
  end

  test "a resolver that is not running yields no BGP data either" do
    assert LS.Cluster.WorkerAgent.bgp_lookup(:no_such_bgp_resolver, ["203.0.113.1"], 100) == %{}
  end
end
