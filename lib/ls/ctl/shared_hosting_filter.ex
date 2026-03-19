defmodule LS.CTL.SharedHostingFilter do
  @moduledoc """
  Filter out shared hosting platforms.
  Loads platform list from lib/ls/ctl/signatures/shared_hosting_platforms.txt
  """

  # Load platforms from file at compile time
  @external_resource "lib/ls/ctl/signatures/shared_hosting_platforms.txt"
  @shared_platforms "lib/ls/ctl/signatures/shared_hosting_platforms.txt"
                    |> File.read!()
                    |> String.split("\n", trim: true)
                    |> Enum.reject(&String.starts_with?(&1, "#"))
                    |> Enum.map(&String.trim/1)
                    |> Enum.reject(&(&1 == ""))

  @doc """
  Check if a domain is a shared hosting platform.

  ## Examples

      iex> shared_platform?("example.pages.dev")
      true

      iex> shared_platform?("mycompany.com")
      false
  """
  def shared_platform?(domain) when is_binary(domain) do
    Enum.any?(@shared_platforms, fn platform ->
      String.ends_with?(domain, platform) or domain == platform
    end)
  end

  @doc "Get list of loaded platforms"
  def list_platforms, do: @shared_platforms
end
