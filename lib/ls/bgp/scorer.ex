defmodule LS.BGP.Scorer do
  @moduledoc """
  Score BGP/ASN data using signature patterns.
  
  Scores based on:
  - ASN organization (AWS, Google, cheap hosts)
  - Country (expensive vs cheap hosting locations)
  - Prefix size (/24 = shared, /28 = dedicated)
  
  Returns scores: bgp_web_scoring, bgp_budget_scoring
  (No security scoring for BGP)
  """
  
  require Logger
  
  @doc """
  Score BGP data.
  
  ## Input
  Map with keys: :asn, :org, :country, :prefix
  
  ## Output
  %{bgp_web_scoring: 0-10, bgp_budget_scoring: 0-10}
  """
  def score(bgp_data) when is_map(bgp_data) do
    # Start with clean slate
    scores = %{web: 0, budget: 0}
    
    # Score each component
    scores
    |> score_asn_org(bgp_data[:org] || bgp_data["org"])
    |> score_country(bgp_data[:country] || bgp_data["country"])
    |> score_prefix(bgp_data[:prefix] || bgp_data["prefix"])
    |> cap_scores()
  rescue
    error ->
      # Graceful error handling
      Logger.warning("BGP Scorer error: #{inspect(error)} for data: #{inspect(bgp_data)}")
      %{bgp_web_scoring: 0, bgp_budget_scoring: 0}
  end
  
  # Score ASN organization (AWS, Google, cheap hosts)
  defp score_asn_org(scores, org) when is_binary(org) and org != "" do
    org_scores = LS.Signatures.score(:bgp_asn_org, org)
    apply_scores(scores, org_scores)
  end
  defp score_asn_org(scores, _), do: scores
  
  # Score country (US, CH = expensive, PH, RO = cheap)
  defp score_country(scores, country) when is_binary(country) and country != "" do
    country_scores = LS.Signatures.score(:bgp_country, country)
    apply_scores(scores, country_scores)
  end
  defp score_country(scores, _), do: scores
  
  # Score prefix size (/28 = dedicated, /16 = shared)
  defp score_prefix(scores, prefix) when is_binary(prefix) and prefix != "" do
    prefix_scores = LS.Signatures.score(:bgp_prefix, prefix)
    apply_scores(scores, prefix_scores)
  end
  defp score_prefix(scores, _), do: scores
  
  # Apply signature scores to accumulator
  defp apply_scores(scores, signature_scores) do
    Enum.reduce(signature_scores, scores, fn {type, points}, acc ->
      case type do
        :web -> %{acc | web: acc.web + points}
        :budget -> %{acc | budget: acc.budget + points}
        _ -> acc  # Ignore other types (security, email)
      end
    end)
  end
  
  # Cap scores at 0-10
  defp cap_scores(%{web: web, budget: budget}) do
    %{
      bgp_web_scoring: cap_value(web),
      bgp_budget_scoring: cap_value(budget)
    }
  end
  
  defp cap_value(val) when val < 0, do: 0
  defp cap_value(val) when val > 10, do: 10
  defp cap_value(val), do: val
end
