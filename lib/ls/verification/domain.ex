defmodule LS.Verification.Domain do
  @moduledoc """
  Reduce a source-published website URL to the registrable domain we key on.

  Uses the same reduction Discovery uses (`LS.CTL.DomainParser`), so a
  Wikidata `http://www.Example.co.uk/en/` and the CT-log `example.co.uk` meet
  on identical bytes. Anything that is not clearly a hostname (IPs, localhost,
  garbage, control characters, IDN we cannot represent) yields `nil` —
  a `nil` here is a record we do not link, never a guess.
  """

  @max_len 253

  @doc """
  Registrable domain of `url`, or `nil`.

      iex> from_url("https://www.Example.co.uk/about?x=1")
      "example.co.uk"
      iex> from_url("doordash.com")
      "doordash.com"
      iex> from_url("http://192.168.0.1/")
      nil
  """
  @spec from_url(term()) :: String.t() | nil
  def from_url(url) when is_binary(url) do
    with s when s != "" <- String.trim(url),
         false <- String.match?(s, ~r/[\x00-\x1f\x7f\s]/),
         true <- byte_size(s) <= 2048,
         host when is_binary(host) <- host(s),
         host <- host |> String.downcase() |> String.trim_trailing("."),
         true <- valid_host?(host),
         {:ok, base, _tld} <- LS.CTL.DomainParser.parse(host) do
      base
    else
      _ -> nil
    end
  end

  def from_url(_), do: nil

  defp host(s) do
    s =
      cond do
        String.contains?(s, "://") -> s
        # "mailto:x@example.com", "tel:..." — a scheme with no authority is not a website
        Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, s) -> ""
        true -> "http://" <> s
      end

    case URI.parse(s) do
      %URI{host: h} when is_binary(h) and h != "" -> h
      _ -> nil
    end
  end

  # Only LDH ASCII hostnames with at least one dot; no IP literals.
  defp valid_host?(h) do
    byte_size(h) <= @max_len and
      String.contains?(h, ".") and
      h != "localhost" and
      Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/, h) and
      not Regex.match?(~r/^\d+\.\d+\.\d+\.\d+$/, h)
  end

  @doc """
  The name-tier key of one of OUR registrable domains: its first label with
  hyphens removed (`acme-widgets.co.uk` → `acmewidgets`). Must stay identical
  to the SQL in `LS.Verification.Store.rebuild_domain_keys/0`.
  """
  @spec label_key(String.t()) :: String.t()
  def label_key(domain) when is_binary(domain) do
    domain |> String.split(".", parts: 2) |> hd() |> String.replace("-", "")
  end
end
