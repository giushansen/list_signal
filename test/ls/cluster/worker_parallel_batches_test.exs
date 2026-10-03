defmodule LS.Cluster.WorkerParallelBatchesTest do
  use ExUnit.Case, async: true

  alias LS.Cluster.WorkerAgent

  @moduledoc """
  2026-10-03: a worker ran one batch at a time and its fetch budget sat
  idle a third of every cycle (DNS 15 s, merge and ML 18-58 s with no fetch
  in flight). Two staggered batches on a 4 GB node fill the gap; a 2 GB node
  stays at one; the operator can pin either with LS_WORKER_BATCHES.
  """

  test "two batches on a 4 GB node, one on a 2 GB node, by default" do
    assert WorkerAgent.parallel_batches(nil, 3_916) == 2
    assert WorkerAgent.parallel_batches(nil, 15_548) == 2
    assert WorkerAgent.parallel_batches(nil, 1_966) == 1
    assert WorkerAgent.parallel_batches(nil, 0) == 1
  end

  test "the environment pins the count within 1..4 and garbage falls back" do
    assert WorkerAgent.parallel_batches("1", 3_916) == 1
    assert WorkerAgent.parallel_batches("3", 1_966) == 3
    assert WorkerAgent.parallel_batches("9", 3_916) == 2
    assert WorkerAgent.parallel_batches("two", 3_916) == 2
  end
end
