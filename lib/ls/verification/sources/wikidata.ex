defmodule LS.Verification.Sources.Wikidata do
  @moduledoc """
  Wikidata via the public SPARQL endpoint (query.wikidata.org, no key).

  Two listing queries over entities that have an official website (P856) and
  revenue (P2139) / employees (P1128), then per batch of QIDs: revenue and
  employee statements (with their point-in-time qualifier P585 — the newest
  wins), and inception/industry/HQ/country labels. Revenue is converted to USD
  with a fixed table of major currencies (`@usd_rates`) — the original amount
  and unit are kept in `revenue_raw`; unknown units keep the raw value and
  contribute no USD figure.

  WDQS rules we follow: a descriptive User-Agent, one query at a time, pages
  small enough to finish inside their 60 s limit, back-off on 429/5xx.
  """

  require Logger
  alias LS.Verification.{HTTP, Ingest, Domain}

  @endpoint "https://query.wikidata.org/sparql"
  @batch 200
  @entity "http://www.wikidata.org/entity/"

  # Approximate USD per unit (2026-08), QIDs verified against Wikidata labels
  # on 2026-08-18. Brackets are decades wide; FX drift of a few percent cannot
  # move a company across one. Unknown unit → no USD figure, raw kept.
  @usd_rates %{
    "Q4917" => 1.0,        # USD
    "Q4916" => 1.1,        # EUR
    "Q25224" => 1.3,       # GBP
    "Q8146" => 0.0067,     # JPY
    "Q25344" => 1.15,      # CHF
    "Q1104069" => 0.73,    # CAD
    "Q259502" => 0.66,     # AUD
    "Q122922" => 0.095,    # SEK
    "Q132643" => 0.095,    # NOK
    "Q25417" => 0.145,     # DKK
    "Q80524" => 0.012,     # INR
    "Q39099" => 0.14,      # CNY
    "Q41044" => 0.011,     # RUB
    "Q4730" => 0.055,      # MXN
    "Q181907" => 0.055,    # ZAR
    "Q190951" => 0.75,     # SGD
    "Q1472704" => 0.60,    # NZD
    "Q123213" => 0.26,     # PLN
    "Q172872" => 0.028,    # TRY
    "Q202040" => 0.00072,  # KRW
    "Q31015" => 0.128,     # HKD
    "Q131645" => 0.22,     # RON
    "Q131473" => 0.0073,   # ISK
    "Q41588" => 0.000062,  # IDR
    "Q47190" => 0.0028,    # HUF
    "Q173117" => 0.18,     # BRL
    "Q131016" => 0.044,    # CZK
    "Q131309" => 0.27,     # ILS
    "Q208526" => 0.031,    # TWD
    "Q177882" => 0.028,    # THB
    "Q17193" => 0.017,     # PHP
    "Q163712" => 0.22,     # MYR
    "Q200050" => 0.0011,   # CLP
    "Q244819" => 0.00025,  # COP
    "Q200294" => 0.27,     # AED
    "Q199857" => 0.27,     # SAR
    "Q199462" => 0.02,     # EGP
    "Q203567" => 0.00065,  # NGN
    "Q188289" => 0.0036,   # PKR
    "Q192090" => 0.00004,  # VND
    "Q81893" => 0.024,     # UAH
    "Q172540" => 0.56,     # BGN
    "Q202882" => 0.0077    # KES
  }

  @doc """
  Full run: list every entity with a website and revenue or employees (two
  listing queries, ~55 k QIDs), then per batch of `@batch` QIDs fetch statements and
  labels with `VALUES` — small queries that finish well inside WDQS's 60 s
  limit (a single ORDER BY/OFFSET sweep over all statements 504s). Records
  stream into ingest batch by batch. Website tier only: every entity has a URL.
  """
  def run(opts \\ []) do
    with {:ok, rev_items} <- fetch(items_query("P2139")),
         {:ok, emp_items} <- fetch(items_query("P1128")) do
      qids = (rev_items ++ emp_items) |> Enum.map(& &1["item"]) |> Enum.filter(&String.starts_with?(&1 || "", "Q")) |> Enum.uniq()
      # WDQS throttles hard (429/502 after ~20 min of steady batches); a run
      # that dies half-way keeps what it stored, and the next run skips the
      # entities already fetched in the last week (the job is weekly) instead of re-asking.
      done = if Keyword.get(opts, :resume, true), do: recently_fetched(), else: MapSet.new()
      qids = Enum.reject(qids, &MapSet.member?(done, &1))
      Logger.info("[VERIFY] wikidata: #{length(qids)} entities to fetch in batches of #{@batch} (#{MapSet.size(done)} already fresh)")

      records =
        qids
        |> Stream.chunk_every(@batch)
        |> Stream.flat_map(fn batch ->
          with {:ok, facts} <- fetch(facts_query(batch)),
               {:ok, meta} <- fetch(meta_query(batch)) do
            {rev, emp} = Enum.split_with(facts, &(&1["kind"] == "rev"))
            build_records(Enum.map(rev, &Map.put(&1, "rev", &1["val"])), Enum.map(emp, &Map.put(&1, "emp", &1["val"])), meta)
          else
            {:error, e} -> raise "wikidata batch failed: #{inspect(e)}"
          end
        end)

      Ingest.ingest(:wikidata, records, url: @endpoint, snapshot: Date.utc_today() |> to_string(), name_tier: false)
    end
  end

  # ── Queries ──

  # One listing per property: the UNION form ran 60 s — exactly WDQS's limit.
  @doc false
  def items_query(prop) when prop in ["P2139", "P1128"] do
    """
    SELECT DISTINCT ?item WHERE { ?item wdt:P856 [] ; wdt:#{prop} [] . }
    """
  end

  @doc false
  def facts_query(qids) do
    """
    SELECT ?item ?website ?kind ?val ?unit ?date WHERE {
      VALUES ?item { #{values(qids)} }
      ?item wdt:P856 ?website .
      { ?item p:P2139 ?st . ?st ps:P2139 ?val . BIND("rev" AS ?kind)
        OPTIONAL { ?st psv:P2139 ?v . ?v wikibase:quantityUnit ?unit . }
        OPTIONAL { ?st pq:P585 ?date . } }
      UNION
      { ?item p:P1128 ?st . ?st ps:P1128 ?val . BIND("emp" AS ?kind)
        OPTIONAL { ?st pq:P585 ?date . } }
    }
    """
  end

  @doc false
  def meta_query(qids) do
    """
    SELECT ?item ?website ?itemLabel ?inception ?industryLabel ?hqLabel ?countryCode WHERE {
      VALUES ?item { #{values(qids)} }
      ?item wdt:P856 ?website .
      OPTIONAL { ?item wdt:P571 ?inception }
      OPTIONAL { ?item wdt:P452 ?industry }
      OPTIONAL { ?item wdt:P159 ?hq }
      OPTIONAL { ?item wdt:P17 ?country . ?country wdt:P297 ?countryCode }
      SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
    }
    """
  end

  defp values(qids), do: Enum.map_join(qids, " ", &"wd:#{&1}")

  defp recently_fetched do
    case LS.Clickhouse.query_raw("SELECT DISTINCT source_id FROM verified_source_records WHERE source = 'wikidata' AND fetched_at > now() - INTERVAL 7 DAY", 120_000) do
      {:ok, rows} -> MapSet.new(rows, &hd/1)
      _ -> MapSet.new()
    end
  end

  # WDQS answers a timed-out query with HTTP 200 and a TRUNCATED JSON body,
  # so a decode failure is a timeout in disguise; 429/502 mean "slow down".
  # Both get long, patient retries here (on top of HTTP's quick ones): a
  # weekly job has hours, and giving up loses the rest of the sweep.
  @patient_retries 6

  defp fetch(query, attempt \\ 1) do
    case HTTP.get_json(@endpoint,
           params: [query: query, format: "json"],
           headers: [{"accept", "application/sparql-results+json"}],
           timeout: 90_000, gap_ms: 4_000) do
      {:ok, %{"results" => %{"bindings" => rows}}} ->
        {:ok, Enum.map(rows, &simplify/1)}

      {:ok, other} ->
        {:error, {:unexpected, inspect(other) |> String.slice(0, 200)}}

      {:error, e} when attempt < @patient_retries ->
        Logger.warning("[VERIFY] wikidata: #{inspect(e) |> String.slice(0, 80)} — pausing #{attempt}m before retry #{attempt}/#{@patient_retries}")
        Process.sleep(60_000 * attempt)
        fetch(query, attempt + 1)

      {:error, e} ->
        {:error, e}
    end
  end

  @doc "Flatten one SPARQL binding row into `%{\"item\" => \"Q42\", \"rev\" => \"123\", ...}` (pure)."
  def simplify(binding) when is_map(binding) do
    Map.new(binding, fn {k, %{"value" => v}} -> {k, strip_entity(v)}; {k, _} -> {k, nil} end)
  end

  defp strip_entity(@entity <> qid), do: qid
  defp strip_entity(v), do: v

  # ── Records (pure) ──

  @doc """
  Combine the three result sets into one record per entity. Newest-dated
  statement wins for revenue and employees; the first website is the link.
  """
  def build_records(rev_rows, emp_rows, meta_rows) do
    rev = best_by_item(rev_rows, "rev")
    emp = best_by_item(emp_rows, "emp")
    meta = Enum.group_by(meta_rows, & &1["item"])

    (Map.keys(rev) ++ Map.keys(emp))
    |> Enum.uniq()
    |> Enum.map(fn qid ->
      m = Map.get(meta, qid, [])
      first = List.first(m) || %{}
      website = first["website"] || get_in(rev, [qid, "website"]) || get_in(emp, [qid, "website"])
      r = rev[qid]
      e = emp[qid]
      {usd, raw} = revenue_usd(r)

      %{
        source: :wikidata,
        source_id: qid,
        name: first["itemLabel"] || qid,
        country: first["countryCode"] || "",
        website: website,
        website_domain: Domain.from_url(website),
        revenue_usd: usd,
        revenue_raw: raw,
        employees: e && to_int(e["emp"]),
        period: (r && year(r["date"])) || (e && year(e["date"])) || "",
        extra:
          %{
            "industry" => m |> Enum.map(& &1["industryLabel"]) |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq() |> Enum.take(3) |> Enum.join(", ") |> nil_if_empty(),
            "inception" => first["inception"] |> year() |> nil_if_empty(),
            "hq" => first["hqLabel"] |> nil_if_empty(),
            "employees_period" => e && year(e["date"])
          }
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
          |> Map.new(),
        source_url: "https://www.wikidata.org/wiki/#{qid}"
      }
    end)
    |> Enum.reject(&is_nil(&1.website_domain))
  end

  defp best_by_item(rows, field) do
    rows
    |> Enum.filter(&(&1["item"] && &1[field]))
    |> Enum.group_by(& &1["item"])
    |> Map.new(fn {qid, rs} -> {qid, Enum.max_by(rs, &(&1["date"] || ""), fn -> hd(rs) end)} end)
  end

  @max_age_years 5

  @doc """
  USD amount and a raw string for a revenue row (pure). A statement older
  than `@max_age_years` (or undated) keeps its raw value but yields no USD
  figure — a 2009 revenue is not a fact about the business today.
  """
  def revenue_usd(row, today \\ Date.utc_today())
  def revenue_usd(nil, _today), do: {nil, ""}

  def revenue_usd(%{"rev" => amount} = r, today) do
    unit = r["unit"] || ""
    y = year(r["date"])
    raw = String.trim("#{amount} #{unit} #{y}")
    # y is nil unless it is exactly four digits (see year/1), so this cannot raise.
    recent? = is_binary(y) and String.to_integer(y) >= today.year - @max_age_years

    case {Float.parse(to_string(amount)), Map.get(@usd_rates, unit)} do
      {{v, _}, rate} when is_number(rate) and v >= 0 and v < 1.0e13 and recent? -> {v * rate, raw}
      _ -> {nil, raw}
    end
  end

  defp to_int(nil), do: nil

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  # Wikidata dates are third-party and NOT always ISO: the SPARQL endpoint also
  # returns "unknown value", "+2021-01-01T00:00:00Z" and other shapes. Taking
  # the first four characters blindly and calling String.to_integer/1 on them
  # raised ArgumentError ("not a textual representation") and killed the whole
  # wikidata verification run after 22s on 2026-08-26. Only a genuine 4-digit
  # year is a year.
  defp year(<<y::binary-size(4), _::binary>>) when is_binary(y) do
    if y =~ ~r/^\d{4}$/, do: y, else: nil
  end

  defp year(_), do: nil

  defp nil_if_empty(nil), do: nil
  defp nil_if_empty(""), do: nil
  defp nil_if_empty(v), do: v
end
