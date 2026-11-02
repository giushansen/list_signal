defmodule LS.CTL.PublicSuffix do
  @moduledoc """
  The registrable name of a hostname, by the public suffix list.

  ## Why (2026-11-02)

  Until this module the parser knew 54 two-part suffixes from a hand-kept
  file, so `shop.example.com.pl` parsed as the name `com.pl`. Every domain
  under com.pl, com.vn, com.hk and a few thousand other suffixes collapsed
  into the suffix itself: `businesses` held 0 of each against 493,177 under
  com.au. The collapsed names then crossed the certificate-rate platform
  rule, so `platforms` learned 985 public suffixes (com.pl and com.vn on
  07-30, org.ph, net.ph, co.it, on.ca...) and the poller dropped everything
  under them as "hosted on a platform".

  The list is the ICANN section of publicsuffix.org, vendored in
  `signatures/public_suffix_list.dat` with unicode rules in punycode,
  because certificate names arrive in punycode. Private-section rules
  (github.io, myshopify.com...) are deliberately left out: those are the
  hosting platforms `LS.CTL.PlatformRegistry` already filters, and treating
  them as suffixes would turn every store on them into a "business".

  ## Rules

  Longest matching rule wins. `*.ck` makes any single label under ck a
  suffix; `!www.ck` says www.ck is registrable despite that. A name that is
  itself a public suffix has no registrable form and parses to `:error`.
  """

  @list_file "lib/ls/ctl/signatures/public_suffix_list.dat"
  @external_resource @list_file

  {rules, wildcards, exceptions} =
    @list_file
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({[], [], []}, fn
      "!" <> rule, {r, w, e} -> {r, w, [rule | e]}
      "*." <> rule, {r, w, e} -> {r, [rule | w], e}
      rule, {r, w, e} -> {[rule | r], w, e}
    end)

  @rules MapSet.new(rules)
  @wildcards MapSet.new(wildcards)
  @exceptions MapSet.new(exceptions)

  @doc "How many rules are loaded (the vendored list has 6,948)."
  @spec rule_count() :: pos_integer()
  def rule_count, do: MapSet.size(@rules) + MapSet.size(@wildcards) + MapSet.size(@exceptions)

  @doc """
  `{:ok, registrable, suffix}` for a hostname, or `:error` when the name is
  a public suffix itself, has one label, or is not a hostname.

      iex> LS.CTL.PublicSuffix.registrable("shop.example.com.pl")
      {:ok, "example.com.pl", "com.pl"}
      iex> LS.CTL.PublicSuffix.registrable("www.example.com")
      {:ok, "example.com", "com"}
      iex> LS.CTL.PublicSuffix.registrable("com.pl")
      :error
  """
  @spec registrable(String.t()) :: {:ok, String.t(), String.t()} | :error
  def registrable(name) when is_binary(name) do
    labels = name |> String.downcase() |> String.trim_trailing(".") |> String.split(".")

    with true <- length(labels) >= 2 and Enum.all?(labels, &(&1 != "")),
         suffix_len when suffix_len < length(labels) <- suffix_length(labels) do
      {:ok, labels |> Enum.take(-(suffix_len + 1)) |> Enum.join("."), labels |> Enum.take(-suffix_len) |> Enum.join(".")}
    else
      _ -> :error
    end
  end

  def registrable(_), do: :error

  @doc "True when the whole name is a public suffix (com, co.uk, com.pl, anything.ck)."
  @spec public_suffix?(String.t()) :: boolean()
  def public_suffix?(name) when is_binary(name) do
    labels = name |> String.downcase() |> String.split(".")
    labels != [] and Enum.all?(labels, &(&1 != "")) and suffix_length(labels) == length(labels)
  end

  def public_suffix?(_), do: false

  # Number of trailing labels that form the public suffix. Walks from the
  # TLD up and keeps the longest rule that matches; the default rule `*`
  # makes every TLD a suffix of length 1.
  defp suffix_length(labels) do
    n = length(labels)

    Enum.reduce(1..n, 1, fn len, best ->
      candidate = labels |> Enum.take(-len) |> Enum.join(".")

      cond do
        MapSet.member?(@exceptions, candidate) -> len - 1
        MapSet.member?(@rules, candidate) -> max(best, len)
        len > 1 and MapSet.member?(@wildcards, labels |> Enum.take(-(len - 1)) |> Enum.join(".")) -> max(best, len)
        true -> best
      end
    end)
  end
end
