defmodule LS.DNS.Parking do
  @moduledoc """
  Nameservers that only parking and domain-sale operators run. A domain
  delegated to one of them is not a business, whatever its page says.

  Measured on prod, 2026-10-01: 156K businesses had such nameservers, 132K
  of them with an empty junk flag, 88K answering 200, 64K with "tech"
  detected on the parking page and classified Marketplace or Directory.
  The page-text detector (`LS.HTTP.BusinessClassifier.junk_reason/1`) only
  knew a dozen phrasings.

  What is deliberately NOT here: hosting defaults that look like parking.
  `dns-parking.com` is Hostinger's standard DNS for every hosted site
  (731K businesses, real ones), `*.registrar-servers.com` is Namecheap's,
  `dnsowl.com` NameSilo's, `porkbun.com` and `domaincontrol.com` are
  ordinary registrar DNS. Only add a marker after checking what it serves.

  One list, two consumers: the worker (`parked_ns?/1`) and the fold
  (`sql/1`), like `LS.DNS.Vendors`.
  """

  @markers ~w(sedoparking.com dovendi.nl dovendi.eu thisdomain.forsale bodis.com parkingcrew.net
              afternic.com dan.com undeveloped.com uniregistrymarket.link above.com parklogic.com
              cashparking.com namedrive.com smartname.com brainydns.com eftydns.com squadhelp.com
              parktons.com hastydns.com rookdns.com trafficz.com internettraffic.com voodoo.com
              ztomy.com sav.com parkingpage.namecheap.com domainmarket.com buydomains.com
              hugedomains.com sedo.com)

  @doc "The host suffixes that identify a parking operator."
  def markers, do: @markers

  @doc "True when any nameserver belongs to a parking operator. Accepts a list or a '|' string."
  @spec parked_ns?(term()) :: boolean()
  def parked_ns?(ns) when is_binary(ns), do: ns |> String.split("|", trim: true) |> parked_ns?()

  def parked_ns?(ns) when is_list(ns) do
    Enum.any?(ns, fn
      n when is_binary(n) ->
        h = n |> String.downcase() |> String.trim_trailing(".")
        Enum.any?(@markers, &(h == &1 or String.ends_with?(h, "." <> &1)))

      _ ->
        false
    end)
  end

  def parked_ns?(_), do: false

  @doc "ClickHouse predicate over an Array(String) expression of nameservers."
  @spec sql(String.t()) :: String.t()
  def sql(array_expr) do
    list = Enum.map_join(@markers, ", ", &"'#{&1}'")

    "arrayExists(ns -> arrayExists(m -> ns = m OR endsWith(ns, concat('.', m)), [#{list}]), " <>
      "arrayMap(x -> trimRight(lower(x), '.'), #{array_expr}))"
  end
end
