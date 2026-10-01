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

  # 2026-10-01, fourth report, and from the FIRST domain ever listed: the
  # owner of morbihan-genealogie.bzh runs the same site on eight TLDs (.bzh
  # .net .org .be .info .biz .fr .eu), all on one address, and the list held
  # for .bzh while the fleet fetched the other seven on 09-30 (503 from
  # their WAF on .net, logged under the canonical .bzh host). A reporter is
  # a name, not a TLD: the first label of every listed domain is a stem that
  # blocks that label under any suffix. Stems shorter than six characters
  # are refused at compile time so a generic label can never block half the
  # web.
  @reported_stems @reported
                  |> Enum.map(fn d -> d |> String.split(".") |> hd() end)
                  |> Enum.uniq()
  for stem <- @reported_stems, String.length(stem) < 6 do
    raise "never-contact stem #{inspect(stem)} is too short to be safe"
  end

  @doc """
  True when `domain` (or any parent of it) has filed an abuse report.

  Accepts anything; a non-binary or unparseable value is simply not on the
  list. Case- and `www.`-insensitive so no caller has to normalize first.
  """
  @spec blocked?(term()) :: boolean()
  def blocked?(domain) when is_binary(domain) do
    d = domain |> String.downcase() |> String.trim_trailing(".")

    Enum.any?(suffixes(d), &MapSet.member?(@reported, &1)) or
      Enum.any?(@reported_words, &String.contains?(d, &1)) or
      registrable_label(d) in @reported_stems
  end

  def blocked?(_), do: false

  @doc "Words that block any domain containing them (see `@reported_words`)."
  @spec words() :: [String.t()]
  def words, do: @reported_words

  @doc "Name stems that block any domain carrying them as a label, on any TLD (see `@reported_stems`)."
  @spec stems() :: [String.t()]
  def stems, do: @reported_stems

  @doc "The current blocklist, for the admin dashboard and tests."
  @spec all() :: MapSet.t()
  def all, do: @reported

  # Second-level suffixes under a two-letter country code: "co.uk", "com.mx",
  # "co.kr". Enough for the stem rule; a full public-suffix list is not
  # needed to tell a reporter's own name from a lookalike that embeds it.
  @second_level ~w(co com net org gov edu ac ne or)

  @doc false
  # The label a person registered: "www.morbihan-genealogie.net" -> that
  # name; "morbihan-genealogie.co.uk" -> the same. By the owner's standing
  # rule, "xayann-services.com.evil.example" -> "evil": a reporter's name as
  # someone else's subdomain is a lookalike, not the reporter.
  def registrable_label(domain) do
    case domain |> String.split(".") |> Enum.reverse() do
      [tld, sld, label | _] when byte_size(tld) == 2 and sld in @second_level -> label
      [_tld, label | _] -> label
      _ -> nil
    end
  end

  # "a.b.example.com" -> ["a.b.example.com", "b.example.com", "example.com"]
  defp suffixes(domain) do
    parts = String.split(domain, ".")

    parts
    |> Enum.with_index()
    |> Enum.map(fn {_, i} -> parts |> Enum.drop(i) |> Enum.join(".") end)
  end
end
