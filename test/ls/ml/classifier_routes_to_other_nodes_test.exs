defmodule LS.ML.ClassifierRoutesToOtherNodesTest do
  @moduledoc """
  2026-11-07: every dual held its own copy of e5-small (about 500 MB of
  a 0.8 to 1.2 GB worker) and spent 8.6 s of its two cores on a batch of
  30 texts; the same batch took 2.0 s through h1's classifier and 3.1 s
  through the master's, round trip included (measured from par1). A node
  may now hand its texts to other nodes (`LS_ML_NODES`) and run without a
  model (`LS_ML_LOCAL=off`). h1 is at home and goes dark with the power:
  a node that is not connected is skipped at once, one that fails is
  skipped for five minutes, and the batch still gets an answer.
  """
  use ExUnit.Case, async: false

  alias LS.ML.Classifier

  @h1 :"worker_lsh1@10.0.0.7"
  @master :"master@10.0.0.1"

  test "the nodes are asked in the order given, only when connected, never the node itself" do
    assert Classifier.remote_nodes("worker_lsh1@10.0.0.7,master@10.0.0.1", [@master, @h1], 0) == [@h1, @master]
    # h1 dark at home: not in the connection list, so the master is first.
    assert Classifier.remote_nodes("worker_lsh1@10.0.0.7,master@10.0.0.1", [@master], 0) == [@master]
    assert Classifier.remote_nodes("#{Node.self()}", [Node.self()], 0) == []
    assert Classifier.remote_nodes(nil, [@master], 0) == []
    assert Classifier.remote_nodes("", [@master], 0) == []
    assert Classifier.remote_nodes(" , master@10.0.0.1 ,", [@master], 0) == [@master]
  end

  test "a node that failed is skipped for five minutes, then asked again" do
    node = :"ml-test-#{System.unique_integer([:positive])}@10.9.9.9"
    now = System.monotonic_time(:millisecond)
    :persistent_term.put({Classifier, :skip, node}, now + 300_000)
    on_exit(fn -> :persistent_term.erase({Classifier, :skip, node}) end)

    assert Classifier.remote_nodes("#{node}", [node], now) == []
    assert Classifier.remote_nodes("#{node}", [node], now + 300_001) == [node]
  end

  test "a node that cannot be reached costs one miss and is put aside" do
    node = :"ml-gone-#{System.unique_integer([:positive])}@10.9.9.9"
    on_exit(fn -> :persistent_term.erase({Classifier, :skip, node}) end)

    result = Classifier.route({:classify_batch, ["query: shop"]}, 2_000, fn _ -> false end, [node])
    # No remote answer: the local model or nothing, never a crash.
    assert result == :none or match?({:ok, _}, result)
    assert :persistent_term.get({Classifier, :skip, node}, 0) > System.monotonic_time(:millisecond)
  end

  test "a node runs its own model unless told off" do
    assert Classifier.local?(nil)
    assert Classifier.local?("on")
    assert Classifier.local?("")
    refute Classifier.local?("off")
  end

  test "an empty batch asks nobody" do
    assert Classifier.classify_batch([]) == []
  end
end
