defmodule LS.Verification do
  @moduledoc """
  Pipeline 3 — **Verification**: attach facts from authoritative sources to
  domains we already hold (Discovery finds, Enrichment reads, Verification
  proves).

  Sources in v1 — all keyless, plain HTTP, run on ONE node (the master), no
  browser, no IP-spreading, each source's published limits obeyed:

  | source            | what we take                                   | link to a domain          |
  |-------------------|------------------------------------------------|---------------------------|
  | `wikidata`        | revenue (P2139), employees (P1128), industry, inception, HQ | official website (P856) |
  | `yc`              | team size, batch, one-liner (→ mission_summary) | website field             |
  | `sec_edgar`       | latest fiscal-year revenue from XBRL companyfacts | submissions `website`, name+US fallback |
  | `companies_house` | turnover + average employees from filed iXBRL accounts | name + GB               |
  | `sirene` / `inpi` | employee band (Sirene), chiffre d'affaires (INPI ratios) | name + FR             |

  ## Matching — two tiers, nothing fuzzy

  1. `website` — the source publishes a URL; we reduce it to the registrable
     domain (`LS.Verification.Domain.from_url/1`) and require an exact row in
     `domains_current`.
  2. `name_country` — the source's legal name is normalised
     (`LS.Verification.NameMatch.key/1`), gated on the source's country, and
     must match exactly ONE domain label in our product table AND be the only
     record with that key in the source. Anything ambiguous is skipped. A wrong
     "verified" link is worse than none: this tier is expected to match a
     minority and its match rate is reported per run so we can decide whether
     a smarter (LLM-assisted) linker over the persisted unmatched records is
     worth building.

  ## Storage

  * `verification_runs` — one row per fetch/ingest, dated.
  * `verified_source_records` — every parsed record carrying a fact, matched or
    not (the persisted "search"; nobody re-downloads a 2 GB zip to re-ask).
  * `verified_facts` — `(domain, fact, source)` → value; newest wins.
  * `businesses.verified_*` — filled by the compactor with the precedence below.
    `estimated_*` is never touched; readers show verified when present.

  ## Source precedence when several sources disagree

  * revenue:   `sec_edgar > companies_house > inpi > wikidata`
    (audited filings before registry filings before crowd-sourced)
  * employees: `wikidata > sirene > companies_house > yc`
    (Wikidata carries a dated exact count; Sirene is a band; YC is self-declared)
  """

  require Logger
  alias LS.Verification.{Store, Scheduler}

  @sources [:wikidata, :yc, :sec_edgar, :companies_house, :sirene]

  @revenue_precedence ~w(sec_edgar companies_house inpi wikidata)
  @employees_precedence ~w(wikidata sirene companies_house yc)

  @doc "Sources in the order a full pass runs them (highest-precision linkers first)."
  def sources, do: @sources

  @doc "Revenue source precedence, best first."
  def revenue_precedence, do: @revenue_precedence

  @doc "Employees source precedence, best first."
  def employees_precedence, do: @employees_precedence

  @doc """
  Contact address SEC EDGAR requires in the User-Agent (their fair-access
  policy: `Sample Company Name AdminContact@<sample company domain>.com`).
  Configured as `:sec_edgar_contact`; the same UA is sent to every source so
  each one can reach us if we ever misbehave.
  """
  def contact, do: Application.get_env(:ls, :sec_edgar_contact, "will@keybloc.io")

  @doc "The User-Agent every verification request carries."
  def user_agent, do: "ListSignal/1.0 #{contact()}"

  @doc "Where downloaded snapshots live: `<dir>/<source>/<snapshot>/...`, kept dated."
  def data_dir, do: Application.get_env(:ls, :verification_dir, "/home/ls/verification")

  @doc """
  Run one source end to end (fetch → parse → match → store). Sequential and
  synchronous; the scheduler calls this, and so can an operator via rpc.
  """
  @spec run(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(source, opts \\ []) when source in @sources do
    mod = source_module(source)
    Logger.info("[VERIFY] #{source}: starting")
    t0 = System.monotonic_time(:millisecond)

    try do
      result = mod.run(opts)
      Logger.info("[VERIFY] #{source}: #{inspect(result)} in #{System.monotonic_time(:millisecond) - t0}ms")
      result
    rescue
      e ->
        Logger.error("[VERIFY] #{source} crashed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc "Run every source in precedence order. Hours; meant for rpc / the scheduler."
  def run_all(opts \\ []), do: Enum.map(@sources, &{&1, run(&1, opts)})

  @doc false
  def source_module(:wikidata), do: LS.Verification.Sources.Wikidata
  def source_module(:yc), do: LS.Verification.Sources.YC
  def source_module(:sec_edgar), do: LS.Verification.Sources.EDGAR
  def source_module(:companies_house), do: LS.Verification.Sources.CompaniesHouse
  def source_module(:sirene), do: LS.Verification.Sources.Sirene

  # ── Bracket helpers (product vocabulary = the estimator's) ──

  @doc """
  Revenue in USD → the estimator's bracket label, so `verified_revenue` filters
  and renders exactly like `estimated_revenue`.
  """
  @spec revenue_bracket(number()) :: String.t()
  def revenue_bracket(usd) when is_number(usd) and usd >= 0 do
    cond do
      usd < 1.0e6 -> "<$1M"
      usd < 1.0e7 -> "$1M-$10M"
      usd < 1.0e8 -> "$10M-$100M"
      usd < 1.0e9 -> "$100M-$1B"
      true -> "$1B+"
    end
  end

  def revenue_bracket(_), do: ""

  @doc "Exact head-count → the estimator's employee bracket label."
  @spec employees_bracket(integer()) :: String.t()
  def employees_bracket(n) when is_integer(n) and n >= 0 do
    cond do
      n <= 10 -> "1-10"
      n <= 50 -> "11-50"
      n <= 500 -> "51-500"
      n <= 5000 -> "501-5000"
      true -> "5001+"
    end
  end

  def employees_bracket(_), do: ""

  @doc """
  What to show a reader: the verified value when we have one, else the
  estimate. Works on any row map with string keys (explorer rows) or atom keys.
  """
  def display(row, field) when field in [:revenue, :employees] do
    v = get(row, "verified_#{field}")
    if v not in [nil, ""], do: v, else: get(row, "estimated_#{field}") || ""
  end

  @doc "True when the displayed value for `field` comes from a verified source."
  def verified?(row, field) when field in [:revenue, :employees],
    do: get(row, "verified_#{field}") not in [nil, ""]

  defp get(row, key) when is_map(row) do
    Map.get(row, key) || Map.get(row, String.to_atom(key))
  end

  @doc """
  Keep only the newest snapshot on disk for `source`. Called after a
  successful run: the archive of what we extracted is `verified_source_records`
  (dated), and the raw files are re-downloadable — a 3 GB EDGAR snapshot per
  run would fill the master's disk in months (2026-06 disk-full → 521 outage).
  """
  def prune_snapshots(source) do
    dir =
      case source do
        :companies_house -> Path.join([data_dir(), "companies_house", "snapshot"])
        s -> Path.join(data_dir(), to_string(s))
      end

    case File.ls(dir) do
      {:ok, entries} when length(entries) > 1 ->
        entries
        |> Enum.sort()
        |> Enum.drop(-1)
        |> Enum.each(&File.rm_rf(Path.join(dir, &1)))

      _ -> :ok
    end
  end

  @doc "Scheduler status for dashboards; safe when the scheduler is not running."
  def status do
    if Process.whereis(Scheduler), do: Scheduler.stats(), else: %{running: false}
  end

  @doc "Match rate per source and tier — the number the linker decision is made on."
  def match_report, do: Store.match_report()
end
