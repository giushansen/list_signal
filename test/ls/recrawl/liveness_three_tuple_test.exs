defmodule LS.Recrawl.LivenessThreeTupleTest do
  @moduledoc """
  2026-10-23: the due list grew a third element (the stored homepage
  simhash) and `partition/2` matched `{d, _}`, so every scheduler tick died
  with a FunctionClauseError after "Found 12500 stale domains" and the
  supervisor restarted it five minutes later: two hours without a single
  refresh enqueued, discovered from the class mix of refreshed rows, not
  from an alert. Any tuple whose first element is the domain must pass.
  """
  use ExUnit.Case, async: true

  alias LS.Recrawl.Liveness

  test "three-element due items partition like two-element ones" do
    due = [{"alive.example", "a", 123}, {"dead.example", "b", 0}]
    resolve = fn
      "dead.example" -> {:error, :nxdomain}
      _ -> {:ok, %{a: ["203.0.113.1"]}}
    end

    assert {:ok, [{"alive.example", "a", 123}], [{"dead.example", "b", 0}]} = Liveness.partition(due, resolve)
  end

  test "the due query and the scheduler agree on three elements" do
    assert LS.Clickhouse.stale_domains_sql(5) =~ "SELECT domain, tier, http_body_simhash FROM ("
  end
end
