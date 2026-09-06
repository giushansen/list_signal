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

  @weights_path "ml/head_v3.json"

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

  # Golden v3 (2026-08-18, 356 fresh rows) measured per-class precision of
  # head-emitted labels. Two classes are structurally untrustworthy from
  # embeddings alone: Government (31-50% — the real ones are caught by the
  # deterministic .gov/.mil TLD rule, so head-Government on other TLDs is
  # mostly municipal-adjacent commercial sites) and FinancialInstitution
  # (29-38% — fires on anything finance-flavored: RE investment firms,
  # credit-fund advisors). Marketplace/Newsletter/Community stay blocked, as
  # in v1 (0-50% at every threshold, tiny support). Media needs 0.8.
  # Effect on golden v3: shipped-ML precision 60% -> 83% at 29% coverage.
  @never_emit ~w(Government FinancialInstitution Marketplace Newsletter Community)
  @min_prob %{"Media" => 0.8}
  @default_min_prob 0.5

  @doc """
  Should a head prediction be shipped as a business_model? Pure decision
  rule, calibrated on golden v3 — see the comment above for the measurements.
  `Junk` is handled by the caller (decline-to-classify), not here.
  """
  def shippable?(class, prob) do
    class not in @never_emit and prob >= Map.get(@min_prob, class, @default_min_prob)
  end
end
