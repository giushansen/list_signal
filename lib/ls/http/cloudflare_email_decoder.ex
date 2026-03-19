defmodule LS.HTTP.CloudflareEmailDecoder do
  @moduledoc """
  Decode Cloudflare Email Protection obfuscation.

  Cloudflare obfuscates emails like:
  <a href="/cdn-cgi/l/email-protection" data-cfemail="4b2e332a263b272e0b2e332a263b272e65282426">

  The data-cfemail attribute contains hex-encoded email with XOR cipher.
  First byte is the key, remaining bytes are XORed with the key.
  """

  @doc """
  Extract and decode all Cloudflare-protected emails from HTML.
  """
  def extract_all(html) when is_binary(html) do
    ~r/data-cfemail="([0-9a-f]+)"/i
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [encoded] -> decode(encoded) end)
    |> Enum.filter(&valid_email?/1)
  end

  def extract_all(_), do: []

  @doc """
  Decode a Cloudflare-obfuscated email.

  ## Examples

      iex> CloudflareEmailDecoder.decode("7b1c1d0a1f7b")
      "test@example.com"
  """
  def decode(encoded) when is_binary(encoded) do
    case hex_to_bytes(encoded) do
      [key | encrypted] when encrypted != [] ->
        encrypted
        |> Enum.map(fn byte -> Bitwise.bxor(byte, key) end)
        |> List.to_string()

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  def decode(_), do: ""

  # Convert hex string to list of bytes
  defp hex_to_bytes(hex) do
    hex
    |> String.downcase()
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] ->
      {int, ""} = Integer.parse("#{a}#{b}", 16)
      int
    end)
  end

  # Basic email validation
  defp valid_email?(email) when is_binary(email) do
    String.contains?(email, "@") and
    String.contains?(email, ".") and
    byte_size(email) > 5 and
    byte_size(email) < 100
  end

  defp valid_email?(_), do: false
end
