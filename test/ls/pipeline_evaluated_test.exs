defmodule LS.PipelineEvaluatedTest do
  use ExUnit.Case, async: true

  @moduledoc """
  2026-10-17: a reachable page with a title and almost no text kept whatever
  label an earlier crawl gave it, because "under 200 characters" meant "not
  observed" and the fold keeps a label no later crawl evaluated.
  gurutulenterprises.com held Marketplace at 0.73 from June on 19
  characters; 28,460 labels sat on such pages in one week.
  """

  alias LS.Pipeline

  test "a thin 2xx page with a real title is evaluated (nothing to classify is a verdict)" do
    assert Pipeline.evaluated?(%{http_status: 200, http_title: "Vendeur", _body_text: "Vendeur", http_blocked: ""})
    assert Pipeline.classification_source(%{business_model: ""}, Pipeline.evaluated?(%{http_status: 200, http_title: "Vendeur", _body_text: "x"})) == "none"
  end

  test "a failed fetch, a wall, a stub title, an empty title and a JS shell are not" do
    refute Pipeline.evaluated?(%{http_status: nil, http_title: "Vendeur", _body_text: ""})
    refute Pipeline.evaluated?(%{http_status: 403, http_title: "Vendeur", _body_text: "x"})
    refute Pipeline.evaluated?(%{http_status: 200, http_title: "Vendeur", _body_text: "x", http_blocked: "cloudflare"})
    refute Pipeline.evaluated?(%{http_status: 200, http_title: "Just a moment...", _body_text: "x"})
    refute Pipeline.evaluated?(%{http_status: 200, http_title: "", _body_text: "x"})
    refute Pipeline.evaluated?(%{http_status: 200, http_title: "App", _body_text: "x", _is_js_site: true})
    refute Pipeline.evaluated?(nil)
  end

  test "an observed page is evaluated as before" do
    assert Pipeline.evaluated?(%{http_status: 200, http_title: "Acme Plumbing", _body_text: String.duplicate("plumbing services ", 20)})
  end
end
