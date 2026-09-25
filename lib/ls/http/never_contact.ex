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
              "xayann-services.com",
              # 2026-09-07: Shinhan Financial Group (KR) CERT via Vultr: one GET /
              # to shinhangroup.com (106.249.55.48) from sg1 at 08:05:10 UTC,
              # HTTP 200, robots.txt allowing, reported as a "sophisticated
              # attack". The whole group and its 106.249.55.0/24 neighbours
              # (shinhantrust.kr), not just the one host: a bank's IDS reports
              # again on any sibling.
              "shinhangroup.com",
              "shinhan.com",
              "shinhan.co.kr",
              "shinhancard.com",
              "shinhaninvest.com",
              "shinhanlife.co.kr",
              "shinhansec.com",
              "shinhantrust.kr",
              "shinhanbank.com",
              # 2026-09-25: the same CERT reported again, this time a browser
              # render on ny2 loading something on one of their hosts on port
              # 10243. Their brand sites outside the list above:
              "shinhanlife.org",
              "shinhancareer.co.kr",
              "shinhandigitalforum.com",
              "shinhanclub.com",
              "shinhan.tech"
            ])

  # 2026-09-25: a whole group, not a list of hosts. Any domain whose name
  # contains one of these is off-limits; the handful of unrelated sites this
  # also catches (a Japanese "kakushinhan.org") are worth nothing next to a
  # third report from a bank's incident-response team.
  @reported_words ["shinhan"]

  @doc """
  True when `domain` (or any parent of it) has filed an abuse report.

  Accepts anything; a non-binary or unparseable value is simply not on the
  list. Case- and `www.`-insensitive so no caller has to normalize first.
  """
  @spec blocked?(term()) :: boolean()
  def blocked?(domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim_trailing(".")
    Enum.any?(suffixes(d), &MapSet.member?(@reported, &1)) or Enum.any?(@reported_words, &String.contains?(d, &1))
  end

  def blocked?(_), do: false

  @doc "Words that block any domain containing them (see `@reported_words`)."
  @spec words() :: [String.t()]
  def words, do: @reported_words

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
