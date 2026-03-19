defmodule LS.DNS.Scorer do
  @moduledoc """
  Scoring logic for DNS enrichment pipeline.

  Calculates web, email, budget, and security scores based on:
  - MX records (email provider quality)
  - TXT records (SPF, DMARC, DKIM, SaaS tools)
  - IPv6 support (modern infrastructure)
  - MX redundancy (multiple servers)
  - CNAME records (tech stack detection!)

  All scores capped at 0-10. Handles nil values gracefully.
  """

  alias LS.Signatures

  # CNAME patterns for tech/infrastructure scoring
  @cname_patterns %{
    # CDN (budget + web + security)
    "cloudflare" => %{budget: 2, web: 2, security: 2},
    "cloudfront" => %{budget: 3, web: 3},
    "fastly" => %{budget: 4, web: 3},
    "akamai" => %{budget: 5, web: 4},
    "cdn77" => %{budget: 2, web: 2},
    "bunnycdn" => %{budget: 2, web: 2},
    "stackpath" => %{budget: 3, web: 2},
    "keycdn" => %{budget: 2, web: 2},
    "edgecast" => %{budget: 3, web: 3},

    # Cloud providers
    "amazonaws.com" => %{budget: 3, web: 3},
    "awsglobalaccelerator" => %{budget: 4, web: 3},
    "azure" => %{budget: 4, web: 3},
    "googleusercontent" => %{budget: 3, web: 3},
    "googleapis" => %{budget: 3, web: 3},
    "digitalocean" => %{budget: 2, web: 2},
    "linode" => %{budget: 2, web: 2},
    "vultr" => %{budget: 2, web: 2},

    # E-commerce platforms
    "shopify" => %{budget: 2, web: 2},
    "myshopify" => %{budget: 2, web: 2},
    "bigcommerce" => %{budget: 3, web: 2},

    # Website builders (lower budget)
    "wix" => %{budget: -1, web: 0},
    "weebly" => %{budget: -1, web: 0},
    "squarespace" => %{budget: 1, web: 1},
    "webflow" => %{budget: 2, web: 2},

    # Modern platforms (high web sophistication)
    "vercel" => %{budget: 2, web: 4},
    "netlify" => %{budget: 2, web: 3},
    "pages.dev" => %{budget: 1, web: 3},
    "workers.dev" => %{budget: 2, web: 4},
    "fly.dev" => %{budget: 2, web: 3},
    "railway" => %{budget: 2, web: 3},
    "render" => %{budget: 2, web: 3},
    "heroku" => %{budget: 2, web: 2},

    # Security/WAF
    "incapsula" => %{budget: 4, security: 4},
    "imperva" => %{budget: 4, security: 4},
    "sucuri" => %{budget: 3, security: 3},

    # Marketing/Sales platforms
    "hubspot" => %{budget: 3, web: 2},
    "marketo" => %{budget: 4, web: 2},
    "pardot" => %{budget: 4, web: 2},
    "salesforce" => %{budget: 5, web: 3},
    "mailchimp" => %{budget: 2, web: 1},

    # Auth providers
    "auth0" => %{budget: 3, security: 3, web: 2},
    "okta" => %{budget: 4, security: 4, web: 2},
    "onelogin" => %{budget: 3, security: 3},

    # Payment platforms
    "stripe" => %{budget: 3, web: 3, security: 2},
    "paypal" => %{budget: 2, web: 1},

    # Customer success
    "zendesk" => %{budget: 3, web: 2},
    "intercom" => %{budget: 3, web: 2},
    "freshdesk" => %{budget: 2, web: 1},
    "drift" => %{budget: 3, web: 2},

    # Dev platforms
    "github" => %{budget: 2, web: 3},
    "gitlab" => %{budget: 2, web: 3},
    "bitbucket" => %{budget: 2, web: 2},

    # Video
    "wistia" => %{budget: 3, web: 2},
    "vimeo" => %{budget: 2, web: 2},
    "youtube" => %{budget: 0, web: 1},

    # Traditional hosting
    "godaddy" => %{budget: 0, web: 0},
    "bluehost" => %{budget: 0, web: 0},
    "hostgator" => %{budget: 0, web: 0},
    "dreamhost" => %{budget: 0, web: 1},
    "siteground" => %{budget: 1, web: 1},

    # Cheap/free hosting (negative)
    "000webhost" => %{budget: -2, web: -1},
    "freenom" => %{budget: -2, web: -1},
  }

  @doc """
  Score DNS enrichment data.
  """
  def score(dns_data) do
    scores = %{web: 0, email: 0, budget: 0, security: 0}

    dns = get_in(dns_data, [:dns]) || %{}

    scores
    |> score_mx_records(dns[:mx] || dns["mx"] || [])
    |> score_txt_records(dns[:txt] || dns["txt"] || [])
    |> score_ipv6(dns[:aaaa] || dns["aaaa"] || [])
    |> score_mx_redundancy(dns[:mx] || dns["mx"] || [])
    |> score_cname_records(dns[:cname] || dns["cname"] || [])
    |> cap_scores()
  rescue
    error ->
      require Logger
      Logger.warning("DNS Scorer error: #{inspect(error)} for data: #{inspect(dns_data)}")
      %{dns_web_scoring: 0, dns_email_scoring: 0, dns_budget_scoring: 0, dns_security_scoring: 0}
  end

  # Score MX records
  defp score_mx_records(scores, mx_records) when is_list(mx_records) and mx_records != [] do
    try do
      mx_string = Enum.join(mx_records, " ")
      mx_scores = Signatures.score(:dns_mx, mx_string)
      merge_scores(scores, mx_scores)
    rescue
      _ -> scores
    end
  end
  defp score_mx_records(scores, _), do: scores

  # Score TXT records
  defp score_txt_records(scores, txt_records) when is_list(txt_records) and txt_records != [] do
    try do
      txt_string = Enum.join(txt_records, " ")
      txt_scores = Signatures.score(:dns_txt, txt_string)
      merge_scores(scores, txt_scores)
    rescue
      _ -> scores
    end
  end
  defp score_txt_records(scores, _), do: scores

  # Score IPv6 support
  defp score_ipv6(scores, aaaa_records) when is_list(aaaa_records) and aaaa_records != [] do
    try do
      %{scores | web: scores.web + 1, security: scores.security + 1}
    rescue
      _ -> scores
    end
  end
  defp score_ipv6(scores, _), do: scores

  # Score MX redundancy
  defp score_mx_redundancy(scores, mx_records) when is_list(mx_records) do
    try do
      count = length(mx_records)

      cond do
        count >= 3 -> %{scores | email: scores.email + 2, budget: scores.budget + 1}
        count == 2 -> %{scores | email: scores.email + 1}
        true -> scores
      end
    rescue
      _ -> scores
    end
  end
  defp score_mx_redundancy(scores, _), do: scores

  # Score CNAME records (tech stack detection)
  defp score_cname_records(scores, cname_records) when is_list(cname_records) and cname_records != [] do
    try do
      cname_string = cname_records
        |> Enum.join(" ")
        |> String.downcase()

      # Find all matching patterns and sum their scores
      cname_scores = @cname_patterns
        |> Enum.filter(fn {pattern, _scores} ->
          String.contains?(cname_string, String.downcase(pattern))
        end)
        |> Enum.reduce(%{web: 0, budget: 0, security: 0, email: 0}, fn {_pattern, pattern_scores}, acc ->
          %{
            web: acc.web + Map.get(pattern_scores, :web, 0),
            budget: acc.budget + Map.get(pattern_scores, :budget, 0),
            security: acc.security + Map.get(pattern_scores, :security, 0),
            email: acc.email + Map.get(pattern_scores, :email, 0)
          }
        end)

      %{
        web: scores.web + cname_scores.web,
        budget: scores.budget + cname_scores.budget,
        security: scores.security + cname_scores.security,
        email: scores.email + cname_scores.email
      }
    rescue
      _ -> scores
    end
  end
  defp score_cname_records(scores, _), do: scores

  # Merge signature scores
  defp merge_scores(acc, score_list) when is_list(score_list) do
    try do
      Enum.reduce(score_list, acc, fn {type, points}, acc ->
        if type in [:web, :email, :budget, :security] do
          current_value = Map.get(acc, type, 0)
          Map.put(acc, type, current_value + points)
        else
          acc
        end
      end)
    rescue
      _ -> acc
    end
  end
  defp merge_scores(acc, _), do: acc

  # Cap all scores at 0-10
  defp cap_scores(scores) do
    try do
      %{
        dns_web_scoring: cap(scores[:web] || 0),
        dns_email_scoring: cap(scores[:email] || 0),
        dns_budget_scoring: cap(scores[:budget] || 0),
        dns_security_scoring: cap(scores[:security] || 0)
      }
    rescue
      _ ->
        %{dns_web_scoring: 0, dns_email_scoring: 0, dns_budget_scoring: 0, dns_security_scoring: 0}
    end
  end

  defp cap(score) when is_number(score) and score < 0, do: 0
  defp cap(score) when is_number(score) and score > 10, do: 10
  defp cap(score) when is_number(score), do: score
  defp cap(_), do: 0
end
