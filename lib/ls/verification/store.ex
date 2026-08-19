defmodule LS.Verification.Store do
  @moduledoc """
  ClickHouse side of pipeline 3: run log, source-record archive, facts, and
  the two match tiers as queries.

  Everything is inserted in bounded chunks (`@chunk` rows, JSONEachRow) — a
  Sirene pass is ~5 M records and the master's ClickHouse is capped at 7 G, so
  no call here may ever hold a whole source in memory or in one INSERT.

  The name tier is served by a small side table, `verification_domain_keys`
  (name key + country → domain), rebuilt from `businesses` at the start of a
  name-tier pass in 16 hash shards. Point lookups against it are index reads;
  the alternative — a JOIN of a 5 M-row source against 13 M businesses — is
  the memory bomb the compactor already hit once (2026-08-05).
  """

  require Logger
  alias LS.Clickhouse
  alias LS.Verification.{Domain, NameMatch}

  @chunk 5_000
  @key_shards 16

  # ── Runs ──

  @doc "Record the start of a run; returns the `started_at` key of its row."
  def start_run(source, url, snapshot) do
    started = now()
    insert_json("verification_runs", [
      %{source: to_string(source), started_at: started, finished_at: nil, status: "running",
        url: url, snapshot: snapshot, bytes: 0, records: 0, matched_website: 0,
        matched_name_country: 0, error: "", updated_at: started}
    ])
    started
  end

  @doc "Re-emit the run row as finished (newest `updated_at` wins)."
  def finish_run(source, started_at, status, stats) do
    insert_json("verification_runs", [
      %{source: to_string(source), started_at: started_at, finished_at: now(), status: to_string(status),
        url: stats[:url] || "", snapshot: stats[:snapshot] || "", bytes: stats[:bytes] || 0,
        records: stats[:records] || 0, matched_website: stats[:matched_website] || 0,
        matched_name_country: stats[:matched_name_country] || 0,
        error: String.slice(to_string(stats[:error] || ""), 0, 2000), updated_at: now()}
    ])
  end

  # ── Records + facts ──

  @doc """
  Persist a chunk of source records (matched or not) and the facts of the
  matched ones. `records` are maps as built by the source modules; `fetched_at`
  is the run's timestamp so a whole run shares one version.
  """
  def store_chunk(records, fetched_at) do
    rows = Enum.map(records, &record_row(&1, fetched_at))
    :ok = insert_json("verified_source_records", rows)
    facts = rows |> Enum.filter(&(&1.matched_domain != "")) |> Enum.flat_map(&facts_for(&1, fetched_at))
    if facts != [], do: :ok = insert_json("verified_facts", facts)
    {length(rows), length(facts)}
  end

  @doc false
  def record_row(r, fetched_at) do
    %{
      source: to_string(r.source),
      source_id: to_string(r.source_id),
      name: clip(r[:name], 500),
      name_key: NameMatch.key(r[:name]),
      country: to_string(r[:country] || ""),
      website: clip(r[:website], 500),
      website_domain: r[:website_domain] || Domain.from_url(r[:website]) || "",
      revenue_usd: num(r[:revenue_usd]),
      revenue_raw: clip(r[:revenue_raw], 200),
      employees: int(r[:employees]),
      employees_band: to_string(r[:employees_band] || ""),
      period: clip(r[:period], 40),
      extra: Jason.encode!(r[:extra] || %{}) |> clip(4000),
      matched_domain: r[:matched_domain] || "",
      match_method: r[:match_method] || "",
      source_url: clip(r[:source_url], 500),
      fetched_at: fetched_at
    }
  end

  @doc "Facts a matched record contributes (pure); an unmatched row contributes none."
  def facts_for(%{matched_domain: ""}, _fetched_at), do: []

  def facts_for(row, fetched_at) do
    base = %{domain: row.matched_domain, source_id: row.source_id, source: row.source,
             source_url: row.source_url, match_method: row.match_method, period: row.period,
             fetched_at: fetched_at}
    extra = Jason.decode!(row.extra)

    # A source can carry a fact from a sister dataset (Sirene records carry
    # INPI revenue); the fact keeps the dataset it really came from so
    # precedence stays truthful.
    revenue_source = extra["revenue_source"] || row.source

    [
      row.revenue_usd && %{fact: "revenue_usd", value: to_string(round(row.revenue_usd)), raw_value: row.revenue_raw, source: revenue_source},
      row.employees && %{fact: "employees", value: to_string(row.employees), raw_value: to_string(row.employees)},
      row.employees_band != "" && %{fact: "employees_band", value: row.employees_band, raw_value: extra["employees_raw"] || row.employees_band},
      extra["industry"] && %{fact: "industry", value: clip(extra["industry"], 200), raw_value: ""},
      extra["inception"] && %{fact: "inception", value: clip(extra["inception"], 40), raw_value: ""},
      extra["hq"] && %{fact: "hq", value: clip(extra["hq"], 200), raw_value: ""},
      extra["mission"] && %{fact: "mission", value: clip(extra["mission"], 500), raw_value: ""}
    ]
    |> Enum.filter(& &1)
    |> Enum.map(&Map.merge(base, &1))
  end

  # ── Website tier ──

  @doc "Subset of `domains` that exist in `domains_current` (exact join)."
  @spec existing_domains([String.t()]) :: MapSet.t()
  def existing_domains([]), do: MapSet.new()

  def existing_domains(domains) do
    domains
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(MapSet.new(), fn chunk, acc ->
      list = Enum.map_join(chunk, ",", &"'#{Clickhouse.escape_public(&1)}'")
      case Clickhouse.query_raw("SELECT DISTINCT domain FROM domains_current WHERE domain IN (#{list})", 120_000) do
        {:ok, rows} -> Enum.reduce(rows, acc, fn [d], a -> MapSet.put(a, d) end)
        {:error, e} -> raise "existing_domains: #{inspect(e)}"
      end
    end)
  end

  @doc "Apply the website tier to a list of records (sets matched_domain/match_method)."
  def match_website(records) do
    cands = records |> Enum.map(& &1[:website_domain]) |> Enum.reject(&(&1 in [nil, ""]))
    have = existing_domains(cands)

    Enum.map(records, fn r ->
      d = r[:website_domain]
      if d not in [nil, ""] and MapSet.member?(have, d),
        do: Map.merge(r, %{matched_domain: d, match_method: "website"}),
        else: r
    end)
  end

  # ── Name + country tier ──

  @doc """
  Rebuild the lookup table from `businesses`. Sharded so no single INSERT
  SELECT holds more than ~1/16 of the table. The key expression here MUST
  equal `LS.Verification.Domain.label_key/1`.
  """
  def rebuild_domain_keys do
    {:ok, _} = Clickhouse.query_raw("""
    CREATE TABLE IF NOT EXISTS verification_domain_keys
    (name_key String, country LowCardinality(String), domain String)
    ENGINE = MergeTree ORDER BY (name_key, country)
    """)
    {:ok, _} = Clickhouse.query_raw("TRUNCATE TABLE verification_domain_keys")

    for shard <- 0..(@key_shards - 1) do
      {:ok, _} = Clickhouse.query_raw("""
      INSERT INTO verification_domain_keys
      SELECT replaceAll(splitByChar('.', domain)[1], '-', '') AS name_key, inferred_country AS country, domain
      FROM businesses
      WHERE cityHash64(domain) % #{@key_shards} = #{shard} AND inferred_country != '' AND length(name_key) >= 6
      SETTINGS max_threads = 2
      """, 600_000)
    end
    :ok
  end

  @doc "Keys that occur more than once in `source` — never linkable (ambiguous)."
  def duplicate_keys(source) do
    {:ok, rows} = Clickhouse.query_raw("""
    SELECT name_key, country FROM verified_source_records
    WHERE source = '#{Clickhouse.escape_public(to_string(source))}' AND length(name_key) >= 6
    GROUP BY name_key, country HAVING count() > 1
    """, 600_000)
    MapSet.new(rows, fn [k, c] -> {k, c} end)
  end

  @doc "For `{key, country}` pairs, the domains our side holds — only pairs with EXACTLY one."
  def unique_domains_for(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      list = Enum.map_join(chunk, ",", fn {k, c} -> "('#{Clickhouse.escape_public(k)}','#{Clickhouse.escape_public(c)}')" end)
      {:ok, rows} = Clickhouse.query_raw("""
      SELECT name_key, country, groupUniqArray(2)(domain) AS ds
      FROM verification_domain_keys WHERE (name_key, country) IN (#{list})
      GROUP BY name_key, country
      """, 300_000)
      Enum.reduce(rows, acc, fn
        [k, c, [d]], a -> Map.put(a, {k, c}, d)
        _, a -> a
      end)
    end)
  end

  @doc """
  Run the name tier over `source`'s unmatched records of run `fetched_at`.
  Matched records are re-emitted one second later with their link so the
  ReplacingMergeTree collapses to the linked row; their facts are inserted.
  Returns the number matched.
  """
  def match_name_country(source, fetched_at) do
    dups = duplicate_keys(source)
    later = fetched_at |> NaiveDateTime.add(1, :second)
    src = Clickhouse.escape_public(to_string(source))

    Stream.unfold("", fn
      nil -> nil
      last ->
        {:ok, rows} = Clickhouse.query_raw("""
        SELECT source_id, name, name_key, country, website, website_domain, revenue_usd, revenue_raw,
               employees, employees_band, period, extra, source_url
        FROM verified_source_records FINAL
        WHERE source = '#{src}' AND fetched_at = toDateTime('#{ts(fetched_at)}')
          AND matched_domain = '' AND country != '' AND length(name_key) >= 6
          AND source_id > '#{Clickhouse.escape_public(last)}'
        ORDER BY source_id LIMIT #{@chunk}
        """, 300_000)
        case rows do
          [] -> nil
          rows -> {rows, if(length(rows) < @chunk, do: nil, else: List.last(rows) |> hd())}
        end
    end)
    |> Enum.reduce(0, fn rows, matched ->
      recs = Enum.map(rows, &row_to_record(&1, source))
      pairs = recs |> Enum.map(&{&1.name_key, &1.country}) |> Enum.reject(&MapSet.member?(dups, &1))
      found = unique_domains_for(pairs)

      linked =
        recs
        |> Enum.filter(&Map.has_key?(found, {&1.name_key, &1.country}))
        |> Enum.map(&Map.merge(&1, %{matched_domain: found[{&1.name_key, &1.country}], match_method: "name_country"}))

      if linked != [] do
        {n, _} = store_chunk(linked, later)
        matched + n
      else
        matched
      end
    end)
  end

  defp row_to_record([id, name, key, country, website, wd, rev, rev_raw, emp, band, period, extra, url], source) do
    %{source: source, source_id: id, name: name, name_key: key, country: country, website: website,
      website_domain: wd, revenue_usd: rev, revenue_raw: rev_raw, employees: emp, employees_band: band,
      period: period, extra: Jason.decode!(extra), source_url: url}
  end

  # ── Reporting ──

  @doc "Records and matches per source and tier, from the archive itself."
  def match_report do
    {:ok, rows} = Clickhouse.query_raw("""
    SELECT source, count() AS records,
           countIf(match_method = 'website') AS website,
           countIf(match_method = 'name_country') AS name_country,
           countIf(website_domain != '') AS with_website
    FROM verified_source_records FINAL GROUP BY source ORDER BY source
    """, 300_000)
    # ClickHouse quotes UInt64 in JSON; keep the report numeric.
    int = fn v when is_binary(v) -> String.to_integer(v); v -> v end

    Enum.map(rows, fn [s, n, w, nc, ww] ->
      %{source: s, records: int.(n), website: int.(w), name_country: int.(nc), with_website: int.(ww)}
    end)
  end

  # ── Helpers ──

  defp insert_json(table, rows) do
    body = Enum.map_join(rows, "\n", &(&1 |> Map.new(fn {k, v} -> {k, ts(v)} end) |> Jason.encode!()))
    case Clickhouse.insert_raw("INSERT INTO #{table} FORMAT JSONEachRow", body) do
      :ok -> :ok
      {:error, e} -> raise "insert #{table}: #{inspect(e)}"
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  # ClickHouse's default DateTime input is "YYYY-MM-DD hh:mm:ss"; Jason would
  # emit ISO-8601 with a "T", which CH rejects in basic mode.
  defp ts(%NaiveDateTime{} = t), do: t |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()
  defp ts(v), do: v

  defp clip(nil, _), do: ""
  defp clip(s, n) when is_binary(s), do: s |> String.replace(~r/[\x00-\x08\x0b\x0c\x0e-\x1f]/, "") |> String.slice(0, n)
  defp clip(s, n), do: clip(to_string(s), n)

  defp num(nil), do: nil
  defp num(n) when is_number(n) and n >= 0, do: n * 1.0
  defp num(_), do: nil

  defp int(nil), do: nil
  defp int(n) when is_integer(n) and n >= 0 and n < 100_000_000, do: n
  defp int(_), do: nil

  @doc false
  def chunk_size, do: @chunk
end
