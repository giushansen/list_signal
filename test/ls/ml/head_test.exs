defmodule LS.ML.HeadTest do
  use ExUnit.Case, async: true

  alias LS.ML.Head

  # A 2-class toy head where the decision is hand-checkable: class "A" fires
  # on dimension 0, class "B" on dimension 1. Built in a function, not a
  # module attribute — Nx tensors hold refs and cannot be escaped at compile time.
  defp toy do
    %{
      version: "toy",
      classes: ["A", "B"],
      coef: Nx.tensor([[10.0, 0.0, 0.0], [0.0, 10.0, 0.0]]),
      intercept: Nx.tensor([0.0, 0.0])
    }
  end

  test "predict picks the class whose weights align with the embedding" do
    assert {"A", pa} = Head.predict(toy(), [1.0, 0.0, 0.0])
    assert {"B", pb} = Head.predict(toy(), [0.0, 1.0, 0.0])
    assert pa > 0.99 and pb > 0.99
  end

  test "an ambiguous embedding yields a probability near 0.5, not fake certainty" do
    {_class, p} = Head.predict(toy(), [0.5, 0.5, 0.0])
    assert_in_delta p, 0.5, 0.01
  end

  test "the shipped weights file loads with the expected 13x384 shape" do
    head = Head.load()
    assert head, "priv/ml/head_v1.json must load — the ML tier silently falls back to zero-shot cosine without it"
    assert length(head.classes) == 13
    assert "Junk" in head.classes and "LocalBusiness" in head.classes
    assert Nx.shape(head.coef) == {13, 384}
    assert Nx.shape(head.intercept) == {13}
  end

  test "shipped weights produce a valid prediction for a unit embedding" do
    head = Head.load()
    emb = List.duplicate(0.0, 383) |> List.insert_at(0, 1.0)
    {class, prob} = Head.predict(head, emb)
    assert class in head.classes
    assert prob > 0.0 and prob <= 1.0
  end
end
