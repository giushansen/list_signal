defmodule LS.Recrawl.LivenessOutranTest do
  @moduledoc """
  2026-10-26: a lookup that outran its 20 s task was dropped from the tick
  with no item attached (`{:exit, _}` carries none), so a name with lame
  nameservers never reached a worker and never got a check. It now goes to
  the live list like any unknown answer; the worker records what it cannot
  resolve.
  """
  use ExUnit.Case, async: true

  alias LS.Recrawl.Liveness

  test "a lookup that outruns its task stays in the live list with its item intact" do
    due = [{"slow.example", "a", 7}, {"ok.example", "a", 8}, {"dead.example", "b", 9}]

    resolve = fn
      "slow.example" -> Process.sleep(:infinity)
      "dead.example" -> {:ok, %{a: []}}
      _ -> {:ok, %{a: ["203.0.113.1"]}}
    end

    # The task timeout is 20 s in production; the stream is the same code, so
    # a sleeping resolver must be killed and the item still come back.
    assert {:ok, live, dead} = Liveness.partition(due, resolve, 300)
    assert Enum.sort(live) == [{"ok.example", "a", 8}, {"slow.example", "a", 7}]
    assert dead == [{"dead.example", "b", 9}]
  end
end
