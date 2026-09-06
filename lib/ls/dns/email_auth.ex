defmodule LS.DNS.EmailAuth do
  @moduledoc """
  Email authentication records for a domain: DMARC, BIMI and DKIM.

  ## Why (2026-09-06)

  These three records say more about an organisation than any homepage
  word count. A `p=reject` DMARC policy means someone owns email security
  (a mail admin, a security function, or a paid deliverability vendor); a
  BIMI record means a registered trademark and, usually, a Verified Mark
  Certificate that costs about $1,500 a year, which no ten-person shop buys;
  the DKIM selectors in use name the mail and marketing platforms the
  company actually sends from (Google Workspace, Microsoft 365, Mailchimp,
  HubSpot, Salesforce...), which is the tool stack the tech detector cannot
  see on a web page. The revenue estimator already had a DMARC signal, but
  it read the apex TXT record, where DMARC never lives (`_dmarc.<domain>`),
  so it had been voting "micro" for every domain since it was written.

  ## Cost discipline

  DNS is the discovery pipeline's first stage and every domain pays for it,
  so nothing here runs for a domain without MX (no mail, no mail
  authentication). For the rest: one DMARC query; BIMI only when DMARC is
  enforcing (BIMI requires quarantine/reject, so asking otherwise is a
  guaranteed miss); DKIM selectors chosen from the MX provider, at most
  `@max_dkim_probes` queries. Worst case is four small TXT lookups on a
  domain that already had five.

  ## Storage

  `dns_dmarc`: the policy word (`none`, `quarantine`, `reject`) or `` .
  `dns_bimi`: the logo URL (`l=`) or `` .
  `dns_dkim`: the selectors that answered, `|`-joined, e.g. `google|k1`.
  """

  @max_dkim_probes 2

  # Selector, and the platform its presence implies. Probed in this order
  # for a provider; the first @max_dkim_probes that fit the MX are asked.
  @selectors_by_provider %{
    google: ["google"],
    microsoft: ["selector1", "selector2"],
    zoho: ["zoho", "zmail"],
    proton: ["protonmail", "protonmail2"],
    yandex: ["mail"],
    generic: ["default", "dkim"]
  }
  # Marketing platforms send from their own selectors regardless of MX.
  @marketing_selectors ["k1", "hs1-", "mailjet", "s1", "mandrill", "sendgrid", "pm", "everlytickey1", "cm", "mte1", "smtpapi"]

  @type result :: %{dmarc: String.t(), bimi: String.t(), dkim: String.t()}

  @doc """
  Look up the three records for `domain`, given its MX list (as the resolver
  formats them, `"10:aspmx.l.google.com"`). Returns empty strings for a
  domain without MX and never raises.
  """
  @spec lookup(String.t(), [String.t()]) :: result()
  def lookup(domain, mx) when is_binary(domain) and is_list(mx) and mx != [] do
    dmarc = domain |> dmarc_txt() |> parse_dmarc()

    bimi =
      if dmarc in ["quarantine", "reject"],
        do: "default._bimi.#{domain}" |> txt() |> parse_bimi(),
        else: ""

    dkim =
      mx
      |> selectors_for()
      |> Enum.filter(fn sel -> "#{sel}._domainkey.#{domain}" |> txt() |> dkim?() end)
      |> Enum.join("|")

    %{dmarc: dmarc, bimi: bimi, dkim: dkim}
  rescue
    _ -> empty()
  end

  def lookup(_, _), do: empty()

  @doc false
  def empty, do: %{dmarc: "", bimi: "", dkim: ""}

  defp dmarc_txt(domain), do: txt("_dmarc.#{domain}")

  defp txt(name) do
    LS.DNS.Resolver.txt(name)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # ── Pure parsers (tested against hostile input) ──────────────────────────

  @doc """
  The DMARC policy word from a list of TXT strings, or `""`. The record must
  start with `v=DMARC1`; `p=` is the domain policy (`sp=` is for subdomains
  and is ignored). Case-insensitive, whitespace-tolerant, first valid
  record wins.
  """
  @spec parse_dmarc([String.t()] | term()) :: String.t()
  def parse_dmarc(records) when is_list(records) do
    records
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.find(&String.starts_with?(String.trim(&1), "v=dmarc1"))
    |> case do
      nil ->
        ""

      rec ->
        rec
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.find_value("", fn tag ->
          case String.split(tag, "=", parts: 2) do
            [k, v] -> if String.trim(k) == "p", do: v |> String.trim() |> policy_word(), else: nil
            _ -> nil
          end
        end)
    end
  end

  def parse_dmarc(_), do: ""

  defp policy_word(v) when v in ["none", "quarantine", "reject"], do: v
  defp policy_word(_), do: nil

  @doc """
  The BIMI logo URL (`l=`) from a list of TXT strings, or `""`. Requires
  `v=BIMI1` and an https URL; capped so a hostile record cannot bloat a row.
  """
  @spec parse_bimi([String.t()] | term()) :: String.t()
  def parse_bimi(records) when is_list(records) do
    records
    |> Enum.filter(&is_binary/1)
    |> Enum.find(&String.starts_with?(String.downcase(String.trim(&1)), "v=bimi1"))
    |> case do
      nil ->
        ""

      rec ->
        rec
        |> String.split(";")
        |> Enum.map(&String.trim/1)
        |> Enum.find_value("", fn tag ->
          case String.split(tag, "=", parts: 2) do
            [k, v] ->
              if String.downcase(k) == "l" and String.starts_with?(String.downcase(v), "https://"),
                do: v |> String.trim() |> String.replace(["\t", "\n", "|"], "") |> String.slice(0, 200),
                else: nil

            _ ->
              nil
          end
        end)
    end
  end

  def parse_bimi(_), do: ""

  @doc "True when the TXT strings contain a DKIM key record (`v=DKIM1` or a `p=` key)."
  @spec dkim?([String.t()] | term()) :: boolean()
  def dkim?(records) when is_list(records) do
    Enum.any?(records, fn r ->
      is_binary(r) and (String.contains?(String.downcase(r), "v=dkim1") or String.contains?(r, "p=MI"))
    end)
  end

  def dkim?(_), do: false

  @doc """
  Which DKIM selectors to probe for a domain, from its MX hosts. Pure.
  At most `@max_dkim_probes` from the provider list; marketing selectors
  are only probed when the provider list is shorter than the budget.
  """
  @spec selectors_for([String.t()]) :: [String.t()]
  def selectors_for(mx) when is_list(mx) do
    hosts = mx |> Enum.map(&String.downcase(to_string(&1))) |> Enum.join(" ")

    provider =
      cond do
        String.contains?(hosts, "google") -> :google
        String.contains?(hosts, "outlook") or String.contains?(hosts, "microsoft") -> :microsoft
        String.contains?(hosts, "zoho") -> :zoho
        String.contains?(hosts, "proton") -> :proton
        String.contains?(hosts, "yandex") -> :yandex
        true -> :generic
      end

    (Map.fetch!(@selectors_by_provider, provider) ++ @marketing_selectors)
    |> Enum.uniq()
    |> Enum.take(@max_dkim_probes)
  end

  def selectors_for(_), do: []

  @doc false
  def max_dkim_probes, do: @max_dkim_probes
end
