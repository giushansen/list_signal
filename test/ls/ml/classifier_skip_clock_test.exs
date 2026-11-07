defmodule LS.ML.ClassifierSkipClockTest do
  @moduledoc """
  2026-11-07, ny1's first minutes without its own model: every batch got
  no ML label. The skip list defaulted to 0, and the BEAM's monotonic
  clock is negative (-576,460,667,305 ms on ny1), so 0 read as a skip
  far in the future and every node in LS_ML_NODES was left out. The
  first test used now = 0 and could not see it.
  """
  use ExUnit.Case, async: false

  alias LS.ML.Classifier

  test "a node never skipped is asked, on the real clock and on any negative one" do
    node = :"ml-clock-#{System.unique_integer([:positive])}@10.9.9.9"
    assert Classifier.remote_nodes("#{node}", [node], System.monotonic_time(:millisecond)) == [node]
    assert Classifier.remote_nodes("#{node}", [node], -576_460_667_305) == [node]
  end

  test "a skip set on a negative clock holds for five minutes and then lifts" do
    node = :"ml-clock-#{System.unique_integer([:positive])}@10.9.9.9"
    now = -576_460_667_305
    :persistent_term.put({Classifier, :skip, node}, now + 300_000)
    on_exit(fn -> :persistent_term.erase({Classifier, :skip, node}) end)

    assert Classifier.remote_nodes("#{node}", [node], now) == []
    assert Classifier.remote_nodes("#{node}", [node], now + 300_001) == [node]
  end
end
