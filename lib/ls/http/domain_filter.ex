defmodule LS.HTTP.DomainFilter do
  @moduledoc """
  Filters domains to only process high-value ones worth crawling.

  Criteria (based on AWK filter):
  1. English-friendly, high-value TLDs (from signature file)
  2. NOT obvious junk (too short, numeric, multi-hyphen)
  3. HAS MX records (can send mail)
  4. HAS SPF in TXT records (proper email setup)

  This saves crawling resources by only hitting valuable domains.
  """

  require Logger

  @high_value_tlds_file "lib/ls/http/signatures/high_value_tlds.txt"
  @min_domain_length 4  # Reject "aa.io", "sa.com", etc.

  @doc """
  Load high-value TLDs into ETS on startup.
  """
  def load_tlds do
    # Create ETS table if it doesn't exist
    case :ets.whereis(:http_high_value_tlds) do
      :undefined ->
        :ets.new(:http_high_value_tlds, [:set, :public, :named_table])
      _tid ->
        :ets.delete_all_objects(:http_high_value_tlds)
    end

    # Load TLDs from file
    case File.read(@high_value_tlds_file) do
      {:ok, content} ->
        tlds = content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

        Enum.each(tlds, fn tld ->
          :ets.insert(:http_high_value_tlds, {tld, true})
        end)

        Logger.info("✅ Loaded #{length(tlds)} high-value TLDs for HTTP filtering")
        {:ok, length(tlds)}

      {:error, reason} ->
        Logger.error("❌ Failed to load TLD file: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Check if a domain should be crawled based on filtering criteria.

  Returns `true` if domain should be crawled, `false` otherwise.

  ## Parameters
    - domain: The domain name (string)
    - mx: MX records (string, may be empty or contain records)
    - txt: TXT records (string, may be empty or contain records)

  ## Examples

      iex> should_crawl?("example.com", "mx.google.com", "v=spf1 include:_spf.google.com ~all")
      true

      iex> should_crawl?("aa.io", "", "")
      false

      iex> should_crawl?("example123456.com", "mx.google.com", "random txt")
      false
  """
  def should_crawl?(domain, mx, txt) do
    with true <- has_high_value_tld?(domain),
         true <- not_junk_domain?(domain),
         true <- has_mx?(mx),
         true <- has_spf?(txt) do
      true
    else
      _ -> false
    end
  end

  # ============================================================================
  # PRIVATE - FILTER CHECKS
  # ============================================================================

  # 1) Check if domain ends with a high-value TLD
  defp has_high_value_tld?(domain) do
    case :ets.whereis(:http_high_value_tlds) do
      :undefined ->
        # Table not loaded yet — allow the domain through
        true

      _tid ->
        domain_lower = String.downcase(domain)
        tlds = :ets.tab2list(:http_high_value_tlds)
        |> Enum.map(fn {tld, _} -> tld end)
        |> Enum.sort_by(&String.length/1, :desc)

        Enum.any?(tlds, fn tld ->
          String.ends_with?(domain_lower, "." <> tld)
        end)
    end
  end

  # 2) Check domain is not obvious junk
  defp not_junk_domain?(domain) do
    # Extract the domain name without TLD
    domain_part = domain
    |> String.split(".")
    |> List.first()
    |> String.downcase()

    cond do
      # Too short (e.g., "aa.io", "sa.com")
      String.length(domain_part) < @min_domain_length ->
        false

      # Contains 2+ digits (random numeric garbage)
      String.match?(domain_part, ~r/[0-9]{2,}/) ->
        false

      # Multiple hyphens (double-hyphen garbage like "abc-def-ghi.com")
      String.match?(domain, ~r/.*-.*-.*/) ->
        false

      true ->
        true
    end
  end

  # 3) Check has MX records (can send mail)
  defp has_mx?(mx) when is_binary(mx) and mx != "", do: true
  defp has_mx?(_), do: false

  # 4) Check has SPF in TXT records (proper email setup)
  defp has_spf?(txt) when is_binary(txt) do
    String.contains?(txt, "v=spf1")
  end
  defp has_spf?(_), do: false
end
