defmodule LS.Verification.Sources.Sirene do
  @moduledoc """
  France: Sirene (INSEE) legal units for employee bands, INPI/BCE financial
  ratios for revenue — both open data on data.gouv.fr, no key.

  1. **INPI ratios** (`ratios_inpi_bce`, ~6.5 M rows, `;`-separated) is
     downloaded once per run and staged in `verification_inpi_ratios`
     (siren, closing date, chiffre d'affaires, type of accounts). Streamed
     line by line.
  2. **Sirene stock** (`StockUniteLegale`, ~26 M legal units, ~1 GB zip) is
     streamed through `unzip -p`. We keep only *companies* — units with a
     `denominationUniteLegale` (individual entrepreneurs carry a person's
     name and must never be linked to a domain), administratively active —
     that have an employee band (`trancheEffectifsUniteLegale`, mapped to our
     brackets by `band_bracket/1`) or an INPI revenue figure. Everything else
     is skipped, not persisted (there is no fact to keep).

  Neither dataset carries a website; linking is name + FR only.
  """

  require Logger
  alias LS.Clickhouse
  alias LS.Verification
  alias LS.Verification.{HTTP, Ingest, Zip, CSV, Store}

  # data.gouv.fr "stable resource" URL → 302 to the current monthly stock file.
  @stock_url "https://www.data.gouv.fr/api/1/datasets/r/825f4199-cadd-486c-ac46-a65a8ea1a047"
  @inpi_url "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/ratios_inpi_bce/exports/csv?use_labels=false&delimiter=%3B"
  @eur_usd 1.1

  # INSEE tranche d'effectifs → our employee bracket. Bands and brackets do
  # not share edges everywhere; each band goes to the bracket that contains
  # its whole range, or the larger part of it (41 = 500-999 → 501-5000).
  @bands %{
    "01" => "1-10", "02" => "1-10", "03" => "1-10",
    "11" => "11-50", "12" => "11-50",
    "21" => "51-500", "22" => "51-500", "31" => "51-500", "32" => "51-500",
    "41" => "501-5000", "42" => "501-5000", "51" => "501-5000",
    "52" => "5001+", "53" => "5001+"
  }

  def run(opts \\ []) do
    ensure_staging()
    snapshot = Date.utc_today() |> Date.beginning_of_month() |> Date.to_iso8601()
    dir = Path.join([Verification.data_dir(), "sirene", snapshot])

    with :ok <- stage_inpi(dir, opts),
         {:ok, bytes} <- fetch(@stock_url, Path.join(dir, "StockUniteLegale_utf8.zip"), opts) do
      records = stock_records(Path.join(dir, "StockUniteLegale_utf8.zip"))
      Ingest.ingest(:sirene, records, url: @stock_url, snapshot: snapshot, bytes: bytes, name_tier: true)
    end
  end

  defp fetch(url, path, opts) do
    if File.exists?(path) and !opts[:force], do: {:ok, File.stat!(path).size}, else: HTTP.download(url, path)
  end

  # ── INPI ratios → staging ──

  defp ensure_staging do
    {:ok, _} = Clickhouse.query_raw("""
    CREATE TABLE IF NOT EXISTS verification_inpi_ratios
    (siren String, closing Date, revenue_eur Float64, kind LowCardinality(String), fetched_at DateTime)
    ENGINE = ReplacingMergeTree(fetched_at) ORDER BY (siren, closing, kind)
    """)
  end

  defp stage_inpi(dir, opts) do
    path = Path.join(dir, "ratios_inpi_bce.csv")
    started = Store.start_run(:inpi, @inpi_url, Path.basename(dir))

    with {:ok, bytes} <- fetch(@inpi_url, path, opts) do
      lines = File.stream!(path, [], :line) |> Stream.map(&String.trim_trailing(&1, "\n"))
      {:ok, idx} = lines |> Enum.take(1) |> hd() |> CSV.header_index(";")

      n =
        lines
        |> Stream.drop(1)
        |> Stream.map(&parse_ratio(&1, idx))
        |> Stream.reject(&is_nil/1)
        |> Stream.chunk_every(Store.chunk_size())
        |> Enum.reduce(0, fn rows, n ->
          body = Enum.map_join(rows, "\n", &Jason.encode!(Map.put(&1, :fetched_at, NaiveDateTime.to_string(started))))
          :ok = Clickhouse.insert_raw("INSERT INTO verification_inpi_ratios FORMAT JSONEachRow", body)
          n + length(rows)
        end)

      Store.finish_run(:inpi, started, :ok, %{url: @inpi_url, snapshot: Path.basename(dir), bytes: bytes, records: n})
      Logger.info("[VERIFY] inpi: staged #{n} ratio rows")
      :ok
    else
      {:error, e} = err ->
        Store.finish_run(:inpi, started, :error, %{url: @inpi_url, error: inspect(e)})
        err
    end
  end

  @doc "One INPI ratios line → `%{siren, closing, revenue_eur, kind}` or nil (pure)."
  def parse_ratio(line, idx) do
    with {:ok, f} <- CSV.parse_line(line, ";"),
         siren when byte_size(siren) == 9 <- at(f, idx, "siren"),
         {ca, ""} <- Float.parse(at(f, idx, "chiffre_d_affaires")),
         true <- ca >= 0 and ca < 1.0e12,
         closing when byte_size(closing) == 10 <- at(f, idx, "date_cloture_exercice") do
      %{siren: siren, closing: closing, revenue_eur: ca, kind: at(f, idx, "type_bilan")}
    else
      _ -> nil
    end
  end

  # ── Sirene stock → records ──

  defp stock_records(zip) do
    lines = Zip.stream_lines(zip)
    {:ok, idx} = lines |> Enum.take(1) |> hd() |> CSV.header_index()

    lines
    |> Stream.drop(1)
    |> Stream.map(&parse_unit(&1, idx))
    |> Stream.reject(&is_nil/1)
    |> Stream.chunk_every(Store.chunk_size())
    |> Stream.flat_map(&with_revenue/1)
  end

  @doc """
  One Sirene stock line → `%{siren, name, band, band_year, naf, created}` or nil.
  Persons (no denomination) and inactive units are dropped (pure).
  """
  def parse_unit(line, idx) do
    with {:ok, f} <- CSV.parse_line(line),
         "A" <- at(f, idx, "etatAdministratifUniteLegale"),
         name when name != "" <- at(f, idx, "denominationUniteLegale"),
         siren when byte_size(siren) == 9 <- at(f, idx, "siren") do
      band = at(f, idx, "trancheEffectifsUniteLegale")
      %{siren: siren, name: name, band: (if Map.has_key?(@bands, band), do: band, else: ""),
        band_year: at(f, idx, "anneeEffectifsUniteLegale"), naf: at(f, idx, "activitePrincipaleUniteLegale"),
        created: at(f, idx, "dateCreationUniteLegale")}
    else
      _ -> nil
    end
  end

  @doc "INSEE band code → our employee bracket, or `\"\"` (pure)."
  def band_bracket(code), do: Map.get(@bands, code, "")

  defp with_revenue(units) do
    list = Enum.map_join(units, ",", &"'#{&1.siren}'")
    {:ok, rows} = Clickhouse.query_raw("""
    SELECT siren, argMax(revenue_eur, (closing, kind != 'K')), max(closing)
    FROM verification_inpi_ratios WHERE siren IN (#{list}) GROUP BY siren
    """, 120_000)
    rev = Map.new(rows, fn [s, ca, c] -> {s, {ca, c}} end)

    units
    |> Enum.filter(&(&1.band != "" or Map.has_key?(rev, &1.siren)))
    |> Enum.map(&record(&1, rev[&1.siren]))
  end

  @doc "Unit + optional `{revenue_eur, closing}` → a record (pure)."
  def record(u, rev) do
    {ca, closing} = rev || {nil, nil}

    %{
      source: :sirene,
      source_id: u.siren,
      name: u.name,
      country: "FR",
      website: "",
      website_domain: nil,
      revenue_usd: ca && ca * @eur_usd,
      revenue_raw: ca && "#{ca} EUR FY-end #{closing} (INPI)",
      employees_band: band_bracket(u.band),
      period: (closing && String.slice(to_string(closing), 0, 4)) || u.band_year,
      extra:
        %{"industry" => u.naf, "inception" => String.slice(u.created, 0, 4),
          "employees_raw" => (u.band != "" && "tranche #{u.band} (#{u.band_year})") || nil,
          "revenue_source" => ca && "inpi"}
        |> Enum.reject(fn {_, v} -> v in [nil, "", false] end)
        |> Map.new(),
      source_url: "https://annuaire-entreprises.data.gouv.fr/entreprise/#{u.siren}"
    }
  end

  defp at(fields, idx, col) do
    case Map.fetch(idx, col) do
      {:ok, i} -> Enum.at(fields, i, "") |> String.trim()
      :error -> ""
    end
  end
end
