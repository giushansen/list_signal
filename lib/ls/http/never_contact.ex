defmodule LS.HTTP.NeverContact do
  @moduledoc """
  Domains we must never contact again, by any engine, from any node.

  ## Why this exists (2026-09-04)

  Two Vultr abuse reports in one week (morbihan-genealogie.bzh 2026-08,
  xayann-services.com 2026-09-04), each threatening "mitigation or VPS
  termination". Losing the Vultr account is an existential risk on the same
  level as IP blacklisting, so a site that has reported us once is
  permanently off-limits: no recrawl, no enrichment, no browser render.
  The data we lose on a handful of hostile domains is worth nothing next to
  the fleet.

  ## Adding a domain

  When an abuse report arrives, add the base domain (no `www.`) to
  `@reported`, in the same change as the incident note in
  `docs/engineering-log.md`. The check matches the domain itself and any
  subdomain, so `www.` and friends are covered.

  This list is deliberately a module attribute, not config or a DB table: it
  changes only when a report arrives, must ship to every node atomically
  with a deploy, and must be impossible to lose in a cache wipe.
  """

  @reported MapSet.new([
              # 2026-08: Vultr report, expoBMS WAF (dal2 + par1, 31 min apart)
              "morbihan-genealogie.bzh",
              # 2026-09-04: Vultr report, Xayann WAF (ny1 + dal2, 6h apart)
              "xayann-services.com"
            ])

  @doc """
  True when `domain` (or any parent of it) has filed an abuse report.

  Accepts anything; a non-binary or unparseable value is simply not on the
  list. Case- and `www.`-insensitive so no caller has to normalize first.
  """
  @spec blocked?(term()) :: boolean()
  def blocked?(domain) when is_binary(domain) do
    domain
    |> String.downcase()
    |> String.trim_trailing(".")
    |> suffixes()
    |> Enum.any?(&MapSet.member?(@reported, &1))
  end

  def blocked?(_), do: false

  @doc "The current blocklist, for the admin dashboard and tests."
  @spec all() :: MapSet.t()
  def all, do: @reported

  # "a.b.example.com" -> ["a.b.example.com", "b.example.com", "example.com"]
  defp suffixes(domain) do
    parts = String.split(domain, ".")

    parts
    |> Enum.with_index()
    |> Enum.map(fn {_, i} -> parts |> Enum.drop(i) |> Enum.join(".") end)
  end
end
