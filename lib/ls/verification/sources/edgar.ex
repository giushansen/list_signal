defmodule LS.Verification.Sources.EDGAR do
  @moduledoc """
  SEC EDGAR bulk data (no key; the SEC only asks for a User-Agent that
  identifies you — `LS.Verification.user_agent/0`).

  Two official bulk files, downloaded once per run into
  `<data_dir>/sec_edgar/<date>/`:

  * `companyfacts.zip` — one JSON per XBRL filer with every reported fact.
    We take the latest fiscal-year revenue (`extract_revenue/1`) from the
    us-gaap revenue tags in `@revenue_tags`, restricted to annual reports
    (10-K / 20-F / 40-F) and full-year durations, so a quarterly figure or a
    restated stub period cannot pose as a year.
  * `submissions.zip` — filer metadata; gives us `name`, `website`, SIC and the
    business address for the ~18 k CIKs that had facts. Websites link by the
    `website` tier; filers without one fall back to name + US.

  Both archives are read entry by entry (`LS.Verification.Zip.fold_entries/3`),
  never as a whole.
  """

  require Logger
  alias LS.Verification
  alias LS.Verification.{HTTP, Ingest, Zip, Domain}

  @facts_url "https://www.sec.gov/Archives/edgar/daily-index/xbrl/companyfacts.zip"
  @subs_url "https://www.sec.gov/Archives/edgar/daily-index/bulkdata/submissions.zip"

  @revenue_tags ~w(
    Revenues
    RevenueFromContractWithCustomerExcludingAssessedTax
    RevenueFromContractWithCustomerIncludingAssessedTax
    SalesRevenueNet
    SalesRevenueGoodsNet
    SalesRevenueServicesNet
    RevenuesNetOfInterestExpense
  )
  @annual_forms ~w(10-K 10-K/A 20-F 20-F/A 40-F 40-F/A)

  @us_states ~w(AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC PR VI GU)

  def run(opts \\ []) do
    snapshot = Date.utc_today() |> to_string()
    dir = Path.join([Verification.data_dir(), "sec_edgar", snapshot])
    facts_zip = Path.join(dir, "companyfacts.zip")
    subs_zip = Path.join(dir, "submissions.zip")

    with {:ok, b1} <- fetch(@facts_url, facts_zip, opts),
         {:ok, b2} <- fetch(@subs_url, subs_zip, opts),
         {:ok, facts} <- Zip.fold_entries(facts_zip, %{}, &collect_facts/3),
         _ <- Logger.info("[VERIFY] sec_edgar: #{map_size(facts)} filers with revenue/employees"),
         {:ok, records} <- Zip.fold_entries(subs_zip, [], &collect_records(&1, &2, &3, facts)) do
      Ingest.ingest(:sec_edgar, records, url: @facts_url, snapshot: snapshot, bytes: b1 + b2, name_tier: true)
    end
  end

  defp fetch(url, path, opts) do
    if File.exists?(path) and !opts[:force], do: {:ok, File.stat!(path).size}, else: HTTP.download(url, path, gap_ms: 1_000)
  end

  # ── companyfacts pass ──

  defp collect_facts("CIK" <> _ = name, get_bin, acc) do
    cik = name |> String.trim_leading("CIK") |> String.trim_trailing(".json")

    case Jason.decode(get_bin.()) do
      {:ok, json} ->
        rev = extract_revenue(json)
        emp = extract_employees(json)
        if rev || emp, do: Map.put(acc, cik, %{revenue: rev, employees: emp}), else: acc

      _ -> acc
    end
  end

  defp collect_facts(_, _, acc), do: acc

  @doc """
  Latest full-fiscal-year revenue from a companyfacts JSON (pure).

  Returns `%{val, fy, end, form, tag}` or nil. Candidates: `@revenue_tags` in
  USD, annual forms only, duration 350–380 days, `fp == "FY"`. The newest
  period end wins; ties go to tag priority, then latest filing.
  """
  def extract_revenue(%{"facts" => %{"us-gaap" => gaap}}) when is_map(gaap) do
    @revenue_tags
    |> Enum.with_index()
    |> Enum.flat_map(fn {tag, prio} ->
      (get_in(gaap, [tag, "units", "USD"]) || [])
      |> Enum.filter(&annual?/1)
      |> Enum.map(&%{val: &1["val"], fy: &1["fy"], end: &1["end"], form: &1["form"], tag: tag, prio: prio, filed: &1["filed"] || ""})
    end)
    |> Enum.filter(&(is_number(&1.val) and &1.val >= 0 and &1.val < 1.0e13))
    |> case do
      [] -> nil
      cands -> cands |> Enum.max_by(&{&1.end, -&1.prio, &1.filed}) |> Map.drop([:prio, :filed])
    end
  end

  def extract_revenue(_), do: nil

  @doc "Latest `dei:EntityNumberOfEmployees` (pure); rarely filed but exact when it is."
  def extract_employees(%{"facts" => %{"dei" => %{"EntityNumberOfEmployees" => %{"units" => units}}}}) when is_map(units) do
    units
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(is_number(&1["val"]) and &1["val"] >= 0 and &1["val"] < 10_000_000))
    |> case do
      [] -> nil
      vs -> v = Enum.max_by(vs, &(&1["end"] || "")); %{val: round(v["val"]), end: v["end"]}
    end
  end

  def extract_employees(_), do: nil

  defp annual?(%{"form" => form, "fp" => "FY", "start" => s, "end" => e}) when form in @annual_forms do
    with {:ok, sd} <- Date.from_iso8601(to_string(s)),
         {:ok, ed} <- Date.from_iso8601(to_string(e)) do
      Date.diff(ed, sd) in 350..380
    else
      _ -> false
    end
  end

  defp annual?(_), do: false

  # ── submissions pass ──

  defp collect_records("CIK" <> rest = _name, get_bin, acc, facts) do
    # Continuation files are "CIK##########-submissions-001.json"; skip them.
    cik = String.trim_trailing(rest, ".json")

    case Map.fetch(facts, cik) do
      {:ok, f} when byte_size(cik) == 10 ->
        case Jason.decode(get_bin.()) do
          {:ok, json} -> [record(cik, json, f) | acc]
          _ -> acc
        end

      _ -> acc
    end
  end

  defp collect_records(_, _, acc, _), do: acc

  @doc "Submissions JSON + extracted facts → a record (pure)."
  def record(cik, sub, %{revenue: rev, employees: emp}) do
    website = sub["website"] || ""
    state = get_in(sub, ["addresses", "business", "stateOrCountry"]) || sub["stateOfIncorporation"] || ""
    country = if String.upcase(to_string(state)) in @us_states, do: "US", else: ""

    %{
      source: :sec_edgar,
      source_id: cik,
      name: to_string(sub["name"] || ""),
      country: country,
      website: website,
      website_domain: Domain.from_url(website),
      revenue_usd: rev && rev.val,
      revenue_raw: rev && "#{rev.val} USD FY#{rev.fy} (#{rev.form}, us-gaap:#{rev.tag})",
      employees: emp && emp.val,
      period: (rev && to_string(rev.fy)) || (emp && String.slice(to_string(emp.end), 0, 4)) || "",
      extra:
        %{
          "industry" => sub["sicDescription"],
          "sic" => sub["sic"],
          "tickers" => sub["tickers"],
          "form" => rev && rev.form,
          "period_end" => rev && rev.end
        }
        |> Enum.reject(fn {_, v} -> v in [nil, "", []] end)
        |> Map.new(),
      source_url: "https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK=#{cik}"
    }
  end
end
