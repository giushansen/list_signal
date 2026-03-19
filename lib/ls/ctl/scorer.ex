defmodule LS.CTL.Scorer do
  @moduledoc """
  Scoring logic for CTL (Certificate Transparency Log) pipeline.

  Calculates web, budget, and security scores based on:
  - TLD (premium vs cheap)
  - SSL issuer (paid vs free)
  - Subdomain count and patterns

  All scores capped at 0-10.
  """

  alias LS.Signatures

  @doc """
  Score CTL certificate data.

  ## Examples

      iex> LS.CTL.Scorer.score(%{
        ctl_domain: "example.com",
        ctl_tld: "com",
        ctl_issuer: "Let's Encrypt",
        ctl_subdomain_count: 5,
        ctl_subdomains: "api|staging|admin|www|cdn"
      })
      %{
        ctl_web_scoring: 6,
        ctl_budget_scoring: 1,
        ctl_security_scoring: 2
      }
  """
  def score(cert_data) do
    scores = %{web: 0, budget: 0, security: 0}

    scores
    |> score_tld(cert_data[:ctl_tld])
    |> score_domain_length(cert_data[:ctl_domain])
    |> score_issuer(cert_data[:ctl_issuer])
    |> score_subdomain_count(cert_data[:ctl_subdomain_count])
    |> score_subdomains(cert_data[:ctl_subdomains])
    |> cap_scores()
  end

  # Score TLD (Top Level Domain)
  defp score_tld(scores, nil), do: scores
  defp score_tld(scores, ""), do: scores
  defp score_tld(scores, tld) do
    tld_scores = Signatures.score(:ctl_tld, tld)
    merge_scores(scores, tld_scores)
  end

  # Score domain length (short domains = expensive)
  defp score_domain_length(scores, nil), do: scores
  defp score_domain_length(scores, ""), do: scores
  defp score_domain_length(scores, domain) do
    # Remove TLD to get base name only
    # e.g., "example.com" -> "example" (7 chars)
    base_name = domain |> String.split(".") |> List.first() || domain
    length = String.length(base_name)

    cond do
      length <= 3 ->
        # 3 chars or less = ULTRA premium ($1M-10M+)
        %{scores | budget: scores.budget + 5, web: scores.web + 3}

      length == 4 ->
        # 4 chars = Premium ($100K-1M)
        %{scores | budget: scores.budget + 4, web: scores.web + 2}

      length == 5 ->
        # 5 chars = Expensive ($10K-100K)
        %{scores | budget: scores.budget + 3, web: scores.web + 1}

      length == 6 ->
        # 6 chars = Moderate-expensive ($1K-10K)
        %{scores | budget: scores.budget + 2}

      length == 7 ->
        # 7 chars = Slight premium ($500-2K)
        %{scores | budget: scores.budget + 1}

      true ->
        # 8+ chars = Standard
        scores
    end
  end

  # Score SSL certificate issuer
  defp score_issuer(scores, nil), do: scores
  defp score_issuer(scores, ""), do: scores
  defp score_issuer(scores, "Unknown"), do: scores
  defp score_issuer(scores, issuer) do
    issuer_scores = Signatures.score(:ctl_issuer, issuer)
    merge_scores(scores, issuer_scores)
  end

  # Score subdomain count (more subdomains = more infrastructure)
  defp score_subdomain_count(scores, nil), do: scores
  defp score_subdomain_count(scores, count) when count <= 1, do: scores
  defp score_subdomain_count(scores, count) when count <= 5 do
    scores
    |> Map.update!(:web, &(&1 + 1))
    |> Map.update!(:budget, &(&1 + 1))
  end
  defp score_subdomain_count(scores, count) when count <= 10 do
    scores
    |> Map.update!(:web, &(&1 + 2))
    |> Map.update!(:budget, &(&1 + 1))
  end
  defp score_subdomain_count(scores, _count) do
    # 10+ subdomains = enterprise-level infrastructure
    scores
    |> Map.update!(:web, &(&1 + 3))
    |> Map.update!(:budget, &(&1 + 2))
  end

  # Score individual subdomain patterns
  defp score_subdomains(scores, nil), do: scores
  defp score_subdomains(scores, ""), do: scores
  defp score_subdomains(scores, subdomains) do
    subdomain_scores = subdomains
    |> String.split("|")
    |> Enum.reject(&(&1 == ""))
    |> Enum.flat_map(&Signatures.score(:ctl_subdomain, &1))

    merge_scores(scores, subdomain_scores)
  end

  # Merge signature scores into accumulator (only CTL-relevant types)
  defp merge_scores(acc, score_list) do
    Enum.reduce(score_list, acc, fn {type, points}, acc ->
      # Only merge CTL-relevant score types (web, budget, security)
      if type in [:web, :budget, :security] do
        current_value = Map.get(acc, type, 0)
        Map.put(acc, type, current_value + points)
      else
        # Ignore non-CTL score types like :email
        acc
      end
    end)
  end

  # Cap all scores at 0-10
  defp cap_scores(scores) do
    %{
      ctl_web_scoring: cap(scores.web),
      ctl_budget_scoring: cap(scores.budget),
      ctl_security_scoring: cap(scores.security)
    }
  end

  defp cap(score) when score < 0, do: 0
  defp cap(score) when score > 10, do: 10
  defp cap(score), do: score
end
