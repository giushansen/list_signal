defmodule LS.CTL.DomainParser do
  @moduledoc """
  Parses domains and extracts base domain + TLD.
  Loads ccTLD list from lib/ls/ctl/signatures/cctlds.txt
  """

  # Load ccTLDs from file at compile time
  @external_resource "lib/ls/ctl/signatures/cctlds.txt"
  @cc_tlds "lib/ls/ctl/signatures/cctlds.txt"
           |> File.read!()
           |> String.split("\n", trim: true)
           |> Enum.reject(&String.starts_with?(&1, "#"))
           |> Enum.map(&String.trim/1)
           |> Enum.reject(&(&1 == ""))

  @doc """
  Parse domain into base domain and TLD.

  ## Examples

      iex> parse("www.example.com")
      {:ok, "example.com", "com"}

      iex> parse("api.example.co.uk")
      {:ok, "example.co.uk", "co.uk"}

      iex> parse("shop.example.com.ua")
      {:ok, "example.com.ua", "com.ua"}
  """
  def parse(domain) when is_binary(domain) do
    domain
    |> clean_domain()
    |> extract_base_and_tld()
  end

  defp clean_domain(domain) do
    domain
    |> String.downcase()
    |> String.replace(~r/^\*\./, "")
    |> String.trim()
  end

  defp extract_base_and_tld(domain) do
    parts = String.split(domain, ".")

    case parts do
      parts when length(parts) < 2 ->
        :error

      parts when length(parts) >= 3 ->
        potential_cctld = Enum.slice(parts, -2..-1) |> Enum.join(".")

        if potential_cctld in @cc_tlds do
          base = Enum.slice(parts, -3..-1) |> Enum.join(".")
          {:ok, base, potential_cctld}
        else
          base = Enum.slice(parts, -2..-1) |> Enum.join(".")
          tld = List.last(parts)
          {:ok, base, tld}
        end

      [_name, tld] ->
        {:ok, domain, tld}
    end
  end

  @doc "Get list of loaded ccTLDs"
  def list_cctlds, do: @cc_tlds
end
