defmodule LS.Verification.Sources.CompaniesHouse do
  @moduledoc """
  Companies House (UK) from the free bulk products at
  download.companieshouse.gov.uk — no key, no REST API.

  Two products, two passes:

  1. **Accounts Monthly Data** — one zip per month of every set of accounts
     filed (iXBRL/XBRL, ~100 k files, ~2 GB). Each file is parsed with
     `LS.Verification.IXBRL.extract/1` for turnover + average employees and
     the result is staged in `verification_ch_accounts` (company number,
     period end, values) — chunked inserts, the zip is never held in memory.
     Only months not yet staged are downloaded (`months:` back from the last
     complete month, default 12); the zip is deleted after a successful
     staging unless `keep_files: true` (the staged facts ARE the persisted
     extract; the raw archives are re-downloadable and 2 GB each).
  2. **Basic Company Data** — the monthly snapshot of the whole register
     (~5.5 M rows, streamed line by line). For each company that has staged
     accounts facts we emit a record: legal name, incorporation date, SIC,
     status, plus the latest turnover/employees. There is no website in the
     register, so linking is name + GB only.

  Turnover is filed in GBP; converted at a fixed 1.3 USD (bracket-safe).
  """

  require Logger
  alias LS.Clickhouse
  alias LS.Verification
  alias LS.Verification.{HTTP, Ingest, Zip, IXBRL, CSV, Store}

  @base "https://download.companieshouse.gov.uk"
  @gbp_usd 1.3
  @months ~w(January February March April May June July August September October November December)

  def run(opts \\ []) do
    ensure_staging()
    dir = Path.join(Verification.data_dir(), "companies_house")

    with :ok <- stage_accounts(dir, opts),
         {:ok, snapshot, csv_zip, bytes} <- fetch_snapshot(dir, opts) do
      records = snapshot_records(csv_zip)
      Ingest.ingest(:companies_house, records, url: "#{@base}/#{Path.basename(csv_zip)}", snapshot: snapshot, bytes: bytes, name_tier: true)
    end
  end

  # ── Pass 1: accounts → staging ──

  defp ensure_staging do
    {:ok, _} = Clickhouse.query_raw("""
    CREATE TABLE IF NOT EXISTS verification_ch_accounts
    (company_number String, period_end Date, turnover Nullable(Float64), employees Nullable(UInt32),
     file String, month String, fetched_at DateTime)
    ENGINE = ReplacingMergeTree(fetched_at) ORDER BY (company_number, period_end)
    """)
  end

  @doc "Month labels Companies House uses (`July2026`), newest first, for the last complete `n` months (pure)."
  def month_labels(today \\ Date.utc_today(), n) do
    Enum.map(1..n, fn i ->
      d = today |> Date.beginning_of_month() |> Date.add(-1) |> shift_months(-(i - 1))
      "#{Enum.at(@months, d.month - 1)}#{d.year}"
    end)
  end

  defp shift_months(date, 0), do: date
  defp shift_months(date, n) when n < 0, do: date |> Date.beginning_of_month() |> Date.add(-1) |> shift_months(n + 1)

  defp staged_months do
    {:ok, rows} = Clickhouse.query_raw("SELECT DISTINCT snapshot FROM verification_runs WHERE source = 'companies_house_accounts' AND status = 'ok'")
    MapSet.new(rows, &hd/1)
  end

  defp stage_accounts(dir, opts) do
    done = staged_months()

    month_labels(Keyword.get(opts, :months, 12))
    |> Enum.reject(&MapSet.member?(done, &1))
    |> Enum.each(fn month ->
      # One bad month (404, corrupt download) must not block the other eleven
      # or the register pass; the month's run row carries the error and the
      # next monthly run retries it.
      case stage_month(dir, month, opts) do
        :ok -> :ok
        {:error, e} -> Logger.warning("[VERIFY] companies_house: #{month} skipped: #{inspect(e) |> String.slice(0, 120)}")
      end
    end)

    :ok
  end

  defp stage_month(dir, month, opts) do
    url = "#{@base}/Accounts_Monthly_Data-#{month}.zip"
    path = Path.join([dir, "accounts", "Accounts_Monthly_Data-#{month}.zip"])
    started = Store.start_run(:companies_house_accounts, url, month)

    with {:ok, bytes} <- HTTP.download(url, path),
         {:ok, {n, buf}} <- Zip.fold_entries(path, {0, []}, &stage_entry(&1, &2, &3, month, started)) do
      flush(buf, month, started)
      unless opts[:keep_files], do: File.rm(path)
      Store.finish_run(:companies_house_accounts, started, :ok, %{url: url, snapshot: month, bytes: bytes, records: n})
      Logger.info("[VERIFY] companies_house: staged #{n} filings for #{month}")
      :ok
    else
      {:error, e} = err ->
        Store.finish_run(:companies_house_accounts, started, :error, %{url: url, snapshot: month, error: inspect(e)})
        err
    end
  end

  # Accumulate parsed filings and flush every chunk so memory stays flat.
  defp stage_entry(name, get_bin, {n, buf}, month, started) do
    case parse_filename(name) do
      {:ok, number, date} ->
        facts = IXBRL.extract(get_bin.())

        if map_size(facts) > 0 do
          row = %{company_number: number, period_end: facts[:period_end] || date, turnover: facts[:turnover],
                  employees: facts[:employees], file: Path.basename(name), month: month, fetched_at: started}
          buf = [row | buf]
          if length(buf) >= Store.chunk_size(), do: (flush(buf, month, started); {n + 1, []}), else: {n + 1, buf}
        else
          {n, buf}
        end

      :error -> {n, buf}
    end
  end

  defp flush([], _, _), do: :ok

  defp flush(rows, _month, _started) do
    body = Enum.map_join(rows, "\n", &Jason.encode!(%{&1 | fetched_at: NaiveDateTime.to_string(&1.fetched_at)}))
    :ok = Clickhouse.insert_raw("INSERT INTO verification_ch_accounts FORMAT JSONEachRow", body)
  end

  @doc "`Prod223_2373_00123456_20240331.html` → `{:ok, \"00123456\", \"2024-03-31\"}` (pure)."
  def parse_filename(name) do
    case Regex.run(~r/_([A-Z0-9]{8})_(\d{4})(\d{2})(\d{2})\.(?:html|xml)$/i, Path.basename(name)) do
      [_, number, y, m, d] -> {:ok, String.upcase(number), "#{y}-#{m}-#{d}"}
      _ -> :error
    end
  end

  # ── Pass 2: register snapshot → records ──

  defp fetch_snapshot(dir, opts) do
    first = Date.utc_today() |> Date.beginning_of_month()
    snapshot = Date.to_iso8601(first)
    file = "BasicCompanyDataAsOneFile-#{snapshot}.zip"
    path = Path.join([dir, "snapshot", file])

    if File.exists?(path) and !opts[:force] do
      {:ok, snapshot, path, File.stat!(path).size}
    else
      case HTTP.download("#{@base}/#{file}", path) do
        {:ok, bytes} -> {:ok, snapshot, path, bytes}
        err -> err
      end
    end
  end

  # Stream the CSV; per chunk of lines, look the numbers up in staging and
  # emit records only for companies that have accounts facts.
  defp snapshot_records(csv_zip) do
    lines = Zip.stream_lines(csv_zip)
    header = lines |> Enum.take(1) |> hd()
    {:ok, idx} = CSV.header_index(header)

    lines
    |> Stream.drop(1)
    |> Stream.map(&parse_row(&1, idx))
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(Store.chunk_size())
    |> Stream.flat_map(&with_facts/1)
  end

  @doc "One register CSV line → `%{number, name, status, incorporated, sic, category}` or nil (pure)."
  def parse_row(line, idx) do
    with {:ok, f} <- CSV.parse_line(line),
         number when number != "" <- at(f, idx, "CompanyNumber"),
         "United Kingdom" <- at(f, idx, "CountryOfOrigin") do
      %{number: number, name: at(f, idx, "CompanyName"), status: at(f, idx, "CompanyStatus"),
        incorporated: at(f, idx, "IncorporationDate"), category: at(f, idx, "CompanyCategory"),
        sic: [at(f, idx, "SICCode.SicText_1"), at(f, idx, "SICCode.SicText_2")] |> Enum.reject(&(&1 == "")) |> Enum.join("; ")}
    else
      _ -> nil
    end
  end

  defp at(fields, idx, col) do
    case Map.fetch(idx, col) do
      {:ok, i} -> Enum.at(fields, i, "") |> String.trim()
      :error -> ""
    end
  end

  defp with_facts(rows) do
    list = Enum.map_join(rows, ",", &"'#{Clickhouse.escape_public(&1.number)}'")
    {:ok, found} = Clickhouse.query_raw("""
    SELECT company_number, argMax(turnover, period_end), argMax(employees, period_end), max(period_end)
    FROM verification_ch_accounts WHERE company_number IN (#{list}) GROUP BY company_number
    """, 120_000)
    facts = Map.new(found, fn [n, t, e, p] -> {n, {t, e, p}} end)

    rows
    |> Enum.filter(&Map.has_key?(facts, &1.number))
    |> Enum.map(fn r -> record(r, facts[r.number]) end)
  end

  @doc "Register row + staged facts → a record (pure)."
  def record(r, {turnover, employees, period_end}) do
    %{
      source: :companies_house,
      source_id: r.number,
      name: r.name,
      country: "GB",
      website: "",
      website_domain: nil,
      revenue_usd: turnover && turnover * @gbp_usd,
      revenue_raw: turnover && "#{turnover} GBP FY-end #{period_end}",
      employees: employees && round(employees),
      period: String.slice(to_string(period_end), 0, 4),
      extra:
        %{"industry" => r.sic, "inception" => String.slice(r.incorporated, -4, 4), "status" => r.status, "category" => r.category}
        |> Enum.reject(fn {_, v} -> v in [nil, ""] end)
        |> Map.new(),
      source_url: "https://find-and-update.company-information.service.gov.uk/company/#{r.number}"
    }
  end
end
