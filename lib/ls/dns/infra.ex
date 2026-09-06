defmodule LS.DNS.Infra do
  @moduledoc """
  Infrastructure DNS records that say how big an organisation's IT is:
  reverse DNS of the web host, and the Microsoft records that only exist
  when a company runs Exchange, Microsoft 365 with Teams, or Entra/Intune
  device enrolment (2026-09-06).

  ## Why

  The revenue estimator votes from what a web page and the apex DNS show.
  Two things it could not see:

  * **PTR** of the first A record. `mail.acme.com` or `acme-web-01.acme.net`
    means the company runs or rents its own servers; `srv-4711.hostingco.net`
    or an `amazonaws.com` name means shared or cloud hosting. Dedicated
    infrastructure with a branded reverse name is a mid-market-and-up trait.
  * **Microsoft enterprise records**. `_autodiscover._tcp` SRV exists for
    Exchange (on-prem or hosted); `_sipfederationtls._tcp` SRV exists when
    Teams (or Skype for Business) federation is set up; the
    `enterpriseregistration` CNAME exists when devices are joined to Entra
    ID for Intune management. A twelve-person shop has none of these; an
    organisation with an IT department usually has two or three.

  ## Cost discipline

  DNS is discovery's first stage and every domain pays for it. PTR is one
  query per distinct IP, cached in a bounded ETS table because shared
  hosts and CDNs repeat the same IP thousands of times a day. The three
  Microsoft lookups run only for domains that have MX (no mail, no
  Exchange) and cost at most three small queries.

  ## Storage

  `dns_ptr`: the reverse name of the first A record, or ``.
  `dns_ms_enterprise`: `|`-joined flags among `autodiscover`,
  `sipfederation`, `enterpriseregistration`, or ``.
  """

  @ptr_cache :ls_ptr_cache
  @ptr_ttl_s 7 * 86_400
  @ptr_cap 300_000
  @dns_timeout 2_000

  @type result :: %{ptr: String.t(), ms_enterprise: String.t()}

  @doc "PTR of `ip` (cached) plus the Microsoft enterprise flags for `domain` when it has MX."
  @spec lookup(String.t(), String.t() | nil, [String.t()]) :: result()
  def lookup(domain, ip, mx) when is_binary(domain) do
    %{ptr: ptr(ip), ms_enterprise: if(is_list(mx) and mx != [], do: ms_enterprise(domain), else: "")}
  rescue
    _ -> empty()
  end

  def lookup(_, _, _), do: empty()

  @doc false
  def empty, do: %{ptr: "", ms_enterprise: ""}

  # ── PTR ──────────────────────────────────────────────────────────────────

  @doc "Reverse name for an IPv4 address, cached; `` when none or on any error."
  @spec ptr(String.t() | nil) :: String.t()
  def ptr(ip) when is_binary(ip) and ip != "" do
    ensure_cache()
    now = System.system_time(:second)

    case :ets.lookup(@ptr_cache, ip) do
      [{^ip, {name, expires}}] when expires > now ->
        name

      _ ->
        name = resolve_ptr(ip)
        cache_put(ip, name, now)
        name
    end
  rescue
    _ -> ""
  end

  def ptr(_), do: ""

  defp resolve_ptr(ip) do
    with {:ok, addr} <- :inet.parse_ipv4_address(String.to_charlist(ip)),
         name when is_list(name) and name != [] <- :inet_res.lookup(reverse_name(addr), :in, :ptr, timeout: @dns_timeout) do
      name |> hd() |> to_string() |> String.trim_trailing(".") |> String.downcase() |> String.slice(0, 253)
    else
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  @doc false
  def reverse_name({a, b, c, d}), do: ~c"#{d}.#{c}.#{b}.#{a}.in-addr.arpa"

  defp cache_put(ip, name, now) do
    if :ets.info(@ptr_cache, :size) >= @ptr_cap do
      LS.Cache.evict_to(@ptr_cache, trunc(@ptr_cap * 0.9), {:"$2", {:_, :"$1"}})
    end

    :ets.insert(@ptr_cache, {ip, {name, now + @ptr_ttl_s}})
  end

  defp ensure_cache do
    if :ets.info(@ptr_cache) == :undefined do
      :ets.new(@ptr_cache, [:set, :public, :named_table, read_concurrency: true, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def seed_ptr(ip, name), do: (ensure_cache() && cache_put(ip, name, System.system_time(:second)) && :ok)

  # ── Microsoft enterprise records ────────────────────────────────────────

  @doc "Flags for `domain`: autodiscover, sipfederation, enterpriseregistration."
  @spec ms_enterprise(String.t()) :: String.t()
  def ms_enterprise(domain) when is_binary(domain) do
    [
      if(srv?("_autodiscover._tcp.#{domain}"), do: "autodiscover"),
      if(srv?("_sipfederationtls._tcp.#{domain}"), do: "sipfederation"),
      if(cname?("enterpriseregistration.#{domain}"), do: "enterpriseregistration")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("|")
  rescue
    _ -> ""
  end

  def ms_enterprise(_), do: ""

  defp srv?(name) do
    case :inet_res.lookup(String.to_charlist(name), :in, :srv, timeout: @dns_timeout) do
      [_ | _] -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp cname?(name) do
    case :inet_res.lookup(String.to_charlist(name), :in, :cname, timeout: @dns_timeout) do
      [_ | _] -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # ── Pure classification of a reverse name (used by the estimator) ────────

  @shared_markers ~w(shared host hosting vps cloud server srv static dedicated ip- ip. pool dyn dsl cable customer client compute amazonaws googleusercontent azure linode digitalocean ovh hetzner cloudflare akamai fastly)

  @doc """
  What a reverse name says about the hosting: `:branded` when it carries the
  domain's own name (own or rented dedicated infrastructure), `:shared` when
  it looks like a provider's pool name, `:unknown` otherwise or when empty.
  """
  @spec ptr_kind(String.t(), String.t()) :: :branded | :shared | :unknown
  def ptr_kind(ptr, domain) when is_binary(ptr) and ptr != "" and is_binary(domain) do
    label = domain |> String.downcase() |> String.split(".") |> List.first() || ""
    p = String.downcase(ptr)

    cond do
      String.length(label) >= 4 and String.contains?(p, label) -> :branded
      Enum.any?(@shared_markers, &String.contains?(p, &1)) -> :shared
      true -> :unknown
    end
  end

  def ptr_kind(_, _), do: :unknown
end
