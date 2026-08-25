defmodule LS.CTL.ConsumeRangeTest do
  use ExUnit.Case, async: true

  alias LS.CTL.Poller

  @moduledoc """
  A CT log may return FEWER entries than asked — Google caps get-entries by
  response size, so a 32-entry request can return 7. Found live on
  2026-08-25: the poller claimed [start, start+31], processed the 7 returned,
  and never fetched the other 25 — silent, permanent skips in the product's
  most upstream data, invisible because `behind` still shrank.

  `consume_range/3` must keep fetching until the whole claim is consumed.
  """

  # fetches: list of {:ok, n_entries} | {:error, term} scripts consumed in order.
  defp scripted(fetches) do
    {:ok, agent} = Agent.start_link(fn -> fetches end)

    fn start, endd ->
      case Agent.get_and_update(agent, fn [h | t] -> {h, t}; [] -> {:empty, []} end) do
        {:ok, n} ->
          take = min(n, endd - start + 1)
          {:ok, Enum.map(start..(start + take - 1), fn i -> [%{ctl_domain: "d#{i}.example"}] end)}

        :empty ->
          {:ok, []}

        err ->
          err
      end
    end
  end

  test "a short response is followed up until the claim is fully consumed — the 7-of-32 bug" do
    fetch = scripted([{:ok, 7}, {:ok, 20}, {:ok, 5}])
    {entries, consumed} = Poller.consume_range(0, 31, fetch)

    assert consumed == 32
    assert length(entries) == 32
    # No index skipped, no index doubled.
    domains = entries |> List.flatten() |> Enum.map(& &1.ctl_domain)
    assert length(Enum.uniq(domains)) == 32
  end

  test "an exact response needs exactly one fetch" do
    fetch = scripted([{:ok, 32}])
    {entries, consumed} = Poller.consume_range(0, 31, fetch)
    assert consumed == 32
    assert length(entries) == 32
  end

  test "an error mid-claim keeps what was already fetched instead of losing the whole batch" do
    fetch = scripted([{:ok, 7}, {:error, :timeout}])
    {entries, consumed} = Poller.consume_range(0, 31, fetch)

    assert consumed == 7
    assert length(entries) == 7
  end

  test "a log that keeps returning nothing cannot loop forever" do
    fetch = scripted([])
    {entries, consumed} = Poller.consume_range(0, 31, fetch)

    assert consumed == 0
    assert entries == []
  end
end
