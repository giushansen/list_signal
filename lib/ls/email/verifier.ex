defmodule LS.Email.Verifier do
  @moduledoc """
  Scores published addresses and writes `email_checks`. Master-only, off
  the request path.

  Two entry points. `score_async/1` takes the contact rows a batch just
  wrote (discovery or the depth lane), reads the mail facts of their
  domains in one keyed query each, scores them with `LS.Email.Score` and
  inserts the rows. `backfill/0` is the one-shot over `businesses`
  (2026-10-27): the same rule as SQL, in hash shards, so 11M addresses are
  scored by ClickHouse without a byte crossing into the VM; a row is
  re-scored here at the address's next sighting.
  """

  require Logger

  alias LS.Clickhouse
  alias LS.Schema.Tables

  @shards 32
  @cols ~w(domain email kind score verdict evidence provider source_page last_seen checked_at)

  @doc "Score and store a batch's contact rows in a task; never blocks the caller."
  @spec score_async([map()]) :: :ok
  def score_async([]), do: :ok

  def score_async(rows) when is_list(rows) do
    Task.start(fn ->
      try do
        score_rows(rows)
      rescue
        e -> Logger.warning("[EMAIL] scoring failed: #{Exception.message(e)}")
      end
    end)

    :ok
  end

  def score_async(_), do: :ok

  @doc "Score contact rows (`domain`, `email`, `source_page`, `seen_at`) and write them. Returns the rows written."
  @spec score_rows([map()]) :: [map()]
  def score_rows(rows) when is_list(rows) do
    rows = Enum.filter(rows, &(is_map(&1) and is_binary(&1[:domain]) and is_binary(&1[:email])))
    domains = rows |> Enum.map(& &1.domain) |> Enum.uniq()
    facts = mail_facts(domains)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_string() |> String.slice(0, 19)

    checks =
      for r <- rows, f = Map.get(facts, r.domain, %{}), reduce: [] do
        acc ->
          kind = LS.HTTP.EmailClass.classify(r.email, r.domain)

          if kind in LS.HTTP.EmailClass.sellable() do
            s =
              LS.Email.Score.score(%{
                email: r.email,
                domain: r.domain,
                kind: kind,
                source_page: r[:source_page],
                last_seen: r[:seen_at] || now,
                mx: Map.get(f, :mx, false),
                provider: Map.get(f, :provider, ""),
                spf: Map.get(f, :spf, false),
                dmarc: Map.get(f, :dmarc, false),
                disposable: Map.get(f, :disposable, false)
              })

            [
              %{
                domain: r.domain,
                email: String.downcase(r.email),
                kind: Atom.to_string(kind),
                score: s.score,
                verdict: s.verdict,
                evidence: s.evidence,
                provider: Map.get(f, :provider, ""),
                source_page: r[:source_page] || "homepage",
                last_seen: r[:seen_at] || now,
                checked_at: now
              }
              | acc
            ]
          else
            acc
          end
      end

    write(checks)
    checks
  end

  @doc """
  The one-shot backfill over `businesses`, shard by shard, logging each.
  Returns the number of shards that succeeded. Idempotent: the table is a
  ReplacingMergeTree keyed by (domain, email).
  """
  @spec backfill(keyword()) :: non_neg_integer()
  def backfill(opts \\ []) do
    for shard <- 0..(@shards - 1), reduce: 0 do
      acc ->
        {us, result} = :timer.tc(fn -> Clickhouse.query_raw(LS.Email.Score.backfill_sql(shard, @shards, opts), 660_000, background: true) end)

        case result do
          {:ok, _} ->
            Logger.info("[EMAIL] backfill shard #{shard}/#{@shards} done in #{div(us, 1_000_000)} s")
            acc + 1

          {:error, reason} ->
            Logger.warning("[EMAIL] backfill shard #{shard} failed: #{inspect(reason) |> String.slice(0, 300)}")
            acc
        end
    end
  end

  # ── facts ───────────────────────────────────────────────────────────────

  @doc false
  # MX, provider, DMARC and disposable from the compiled row; SPF from the
  # newest crawl's TXT records. One keyed query each, for the batch.
  def mail_facts([]), do: %{}

  def mail_facts(domains) do
    list = Enum.map_join(domains, ", ", &"'#{Clickhouse.escape_public(&1)}'")

    base =
      case Clickhouse.query_raw("SELECT domain, notEmpty(dns_mx), dns_email_provider, dns_dmarc != '', is_disposable_email FROM #{Tables.businesses()} WHERE domain IN (#{list})", 10_000) do
        {:ok, rows} ->
          Map.new(rows, fn [d, mx, prov, dmarc, disp] -> {d, %{mx: truthy(mx), provider: prov || "", dmarc: truthy(dmarc), disposable: truthy(disp)}} end)

        _ ->
          %{}
      end

    spf =
      case Clickhouse.query_raw("SELECT domain, argMax(dns_txt, enriched_at) FROM #{Tables.enrich_log()} WHERE domain IN (#{list}) AND enriched_at >= now() - INTERVAL 400 DAY GROUP BY domain", 15_000) do
        {:ok, rows} -> Map.new(rows, fn [d, txt] -> {d, String.contains?(to_string(txt || ""), "v=spf1")} end)
        _ -> %{}
      end

    Map.new(domains, fn d -> {d, Map.put(Map.get(base, d, %{}), :spf, Map.get(spf, d, false))} end)
  end

  defp truthy(v), do: v in [1, "1", true]

  defp write([]), do: :ok

  defp write(rows) do
    rows = Enum.map(rows, &Map.update!(&1, :evidence, fn ev -> array_literal(ev) end))
    LS.Cluster.EnrichmentWriter.insert_rows(Tables.email_checks(), @cols, rows)
  end

  @doc """
  The TabSeparated wire form of an Array(String) cell: `['a','b']`, each
  element with backslash and quote escaped once, tabs and newlines
  replaced. Tagged `{:raw, _}` so the writer sends it as is: ClickHouse
  applies the TabSeparated escapes inside the quoted elements, and a
  second escaping pass (2026-10-27 to 10-28) turned `\\'` into `\\\\'`, which
  the server read as a backslash, a closing quote and a stray letter.
  Every evidence list with an apostrophe ("a person's mailbox") failed
  its whole insert: 8,392 batches, every named and free-mail check of the
  day. Pinned by LS.Email.VerifierQuoteTest.
  """
  @spec array_literal(term()) :: {:raw, String.t()}
  def array_literal(list) when is_list(list) do
    inner =
      Enum.map_join(list, ",", fn s ->
        "'" <>
          (s
           |> to_string()
           |> String.replace(["\t", "\n", "\r"], " ")
           |> String.replace("\\", "\\\\")
           |> String.replace("'", "\\'")) <> "'"
      end)

    {:raw, "[" <> inner <> "]"}
  end

  def array_literal(_), do: {:raw, "[]"}
end
