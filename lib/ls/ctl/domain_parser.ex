defmodule LS.CTL.DomainParser do
  @moduledoc """
  Turns a certificate name into the registrable domain and its public
  suffix, through `LS.CTL.PublicSuffix`.

  Until 2026-11-02 this held its own list of 54 two-part suffixes, so any
  other second-level suffix collapsed into itself (`shop.example.com.pl`
  parsed as `com.pl`); see the public suffix module for what that cost.
  """

  alias LS.CTL.PublicSuffix

  @doc """
  Parse a hostname into `{:ok, registrable_domain, public_suffix}`.

      iex> LS.CTL.DomainParser.parse("www.example.com")
      {:ok, "example.com", "com"}
      iex> LS.CTL.DomainParser.parse("api.example.co.uk")
      {:ok, "example.co.uk", "co.uk"}
      iex> LS.CTL.DomainParser.parse("shop.example.com.pl")
      {:ok, "example.com.pl", "com.pl"}
      iex> LS.CTL.DomainParser.parse("com.pl")
      :error
  """
  @spec parse(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse(domain) when is_binary(domain) do
    domain
    |> String.downcase()
    |> String.replace(~r/^\*\./, "")
    |> String.trim()
    |> PublicSuffix.registrable()
  end

  def parse(_), do: :error
end
