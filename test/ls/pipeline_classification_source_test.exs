defmodule LS.PipelineClassificationSourceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-07: "none" is the verdict a worker writes when it read a real page
  and the classifier declined. Without it a withheld label and a failed
  fetch were the same empty string, and the fold kept the stale label.
  """

  alias LS.Pipeline

  test "a label names its tier, a declined observed page says none, an unobserved page says nothing" do
    assert Pipeline.classification_source(%{business_model: "SaaS", source: "ml:head_v3"}, true) == "ml:head_v3"
    assert Pipeline.classification_source(%{business_model: "SaaS"}, false) == "heuristic"
    assert Pipeline.classification_source(%{business_model: "", source: ""}, true) == "none"
    assert Pipeline.classification_source(%{business_model: ""}, false) == ""
    assert Pipeline.classification_source(%{}, false) == ""
  end

  test "the merged result of an undecided ML call on an observed page carries none, not an empty source" do
    heur = %{business_model: "", industry: "", confidence: 0.3}
    ml = %{business_model: "SaaS", industry: "", ml_confidence: 0.6, ml_bm_confidence: 0.6}
    merged = Pipeline.merge_classification(heur, ml)
    assert merged.business_model == ""
    assert Pipeline.classification_source(merged, true) == "none"
  end
end
