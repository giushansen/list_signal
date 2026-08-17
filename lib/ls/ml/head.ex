defmodule LS.ML.Head do
  @moduledoc """
  The trained classification head: a 17-class logistic layer over the MiniLM
  embeddings `LS.ML.Classifier` already computes.

  Weights live in `priv/ml/head_v2.json` — trained 2026-08-17 from 4,158
  Claude-teacher-labeled prod domains (distill v1 2,200 + v2 1,962;
  `analysis/distill/`, and `ls.ml_teacher_labels` in prod ClickHouse). v2 adds
  Government, Nonprofit, Manufacturer and FinancialInstitution so real-world
  organizations get a truthful label instead of the least-wrong SaaS guess
  (cisco.com, nih.gov, 2026-08-17). Confidence is CALIBRATED: on the 71-row
  owner+AI golden holdout, conf ≥ 0.6 → 86% precision, conf ≥ 0.7 → 89%. The
  `"Junk"` class is part of the softmax but is never emitted as a business
  model — a high-confidence Junk vote means "decline to classify", which
  keeps this module's contract identical to the cosine path it replaces.
  `priv/ml/head_v1.json` stays on disk as the rollback.

  Pure math on purpose (weights map in, `{class, prob}` out), so the
  decision rule is testable without loading the 458MB encoder.
  """

  require Logger

  @weights_path "ml/head_v2.json"

  @doc """
  Load head weights from priv. Returns `%{classes: [...], coef: tensor,
  intercept: tensor, version: ...}` or `nil` (callers must fall back to the
  cosine path so a broken weights file can never take the ML tier down).
  """
  def load do
    path = Application.app_dir(:ls, Path.join("priv", @weights_path))

    with {:ok, raw} <- File.read(path),
         {:ok, %{"classes" => classes, "coef" => coef, "intercept" => intercept} = head} <-
           Jason.decode(raw) do
      %{
        version: head["version"] || "unknown",
        classes: classes,
        coef: Nx.tensor(coef, type: :f32),
        intercept: Nx.tensor(intercept, type: :f32)
      }
    else
      err ->
        Logger.error("🧠 ML Head: cannot load #{path} — #{inspect(err)}; falling back to cosine")
        nil
    end
  end

  @doc """
  Predict `{class, probability}` for one embedding (any Nx-compatible 384-dim
  vector). Softmax over `coef · emb + intercept`.
  """
  def predict(%{classes: classes, coef: coef, intercept: intercept}, embedding) do
    logits = coef |> Nx.dot(Nx.tensor(embedding, type: :f32)) |> Nx.add(intercept)
    probs = softmax(logits)
    idx = probs |> Nx.argmax() |> Nx.to_number()
    {Enum.at(classes, idx), probs |> Nx.take(Nx.tensor(idx)) |> Nx.to_number()}
  end

  defp softmax(t) do
    e = Nx.exp(Nx.subtract(t, Nx.reduce_max(t)))
    Nx.divide(e, Nx.sum(e))
  end
end
