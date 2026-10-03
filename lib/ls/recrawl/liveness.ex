defmodule LS.Recrawl.Liveness do
  @moduledoc """
  Resolves the refresh scheduler's due list on the master before any of it
  reaches a worker, and records the businesses whose name no longer
  resolves.

  Why (2026-10-03): a worker writes no row for a domain whose DNS fails
  (data model v2, so a hollow row never blanks `domains`). For a known
  business that means its `http_last_checked_at` never advances, the
  oldest-first due query returns it again 30 minutes later, and the dead
  pile up at the head of the list: 34 of the first 40 due domains failed
  DNS from a laptop, 7 to 11 of the 11 batches each run produced 0 to 2
  rows, and in three hours 65K known businesses were enqueued for 7.5K
  refreshed. The refresh budget was being spent re-asking the same dead
  names.

  So the master resolves the list itself (its pinned Unbound, 50 at a
  time). Dead names get a check recorded: a copy of the domain's newest
  `domains` row with `enriched_at` now, `http_error` 'dns_unresolved',
  `http_status` NULL and `worker` 'master'. A full copy, not a hollow row:
  `domains` is newest-row-wins and `businesses` folds the last non-empty
  value, so the business keeps its last known DNS, title and signals, its
  last check moves to now and its error names the outcome. It comes due
  again after its tier cadence and costs one DNS lookup, never a batch.

  The resolver is checked before it is trusted: three anchor names must
  resolve in the same run, or the run is marked suspect and the whole list
  goes to the workers as before. A master whose resolver broke must never
  declare a million businesses dead (the h1 split-brain of 2026-08 wrote
  45M hollow rows for exactly that reason).
  """

  require Logger

  @anchors ["google.com", "cloudflare.com", "shopify.com"]
  @concurrency 50
  @lookup_timeout_ms 20_000
  @error "dns_unresolved"
  @first_try_ms 4_000
  @second_try_ms 8_000
  # Domains per INSERT. The list travels as a URL query parameter and the
  # first pass sent 10,213 names in one: "HTML Form Exception: Field value
  # too long", nothing recorded. 500 names is about 12 KB.
  @chunk 500

  @type due :: {String.t(), String.t()}

  @doc "The http_error value a dead check records."
  def error, do: @error

  @doc """
  Split the due list into live and dead by resolving each name. `resolve`
  takes a domain and returns the resolver's `{:ok, dns}` or `{:error, _}`.
  `{:error, :resolver_suspect}` when an anchor name fails: trust nothing
  from this run.
  """
  @spec partition([due()], (String.t() -> term())) :: {:ok, [due()], [due()]} | {:error, :resolver_suspect}
  def partition(domains, resolve \\ &resolve/1) do
    if Enum.all?(@anchors, &alive?(resolve.(&1))) do
      {live, dead} =
        domains
        |> Task.async_stream(fn {d, _} = item -> {item, dead?(resolve.(d))} end,
          max_concurrency: @concurrency, timeout: @lookup_timeout_ms, on_timeout: :kill_task, ordered: false)
        |> Enum.reduce({[], []}, fn
          {:ok, {item, true}}, {l, d} -> {l, [item | d]}
          {:ok, {item, false}}, {l, d} -> {[item | l], d}
          # A lookup that outran its task: not evidence of death, let a worker try.
          {:exit, _}, acc -> acc
        end)

      {:ok, Enum.reverse(live), Enum.reverse(dead)}
    else
      {:error, :resolver_suspect}
    end
  end

  @doc """
  Pure: a resolver answer with no A record, or an error, is a dead name.
  `{:unknown, reason}` is neither: the default resolver returns it for a
  timeout or SERVFAIL after two tries, and such a name goes to a worker
  rather than being declared dead on a bad minute.
  """
  @spec dead?(term()) :: boolean()
  def dead?({:unknown, _}), do: false
  def dead?({:ok, dns}) when is_map(dns), do: List.wrap(dns[:a]) == []
  def dead?({:ok, _}), do: true
  def dead?(_), do: true

  @doc "Pure: a positive answer with at least one address."
  @spec alive?(term()) :: boolean()
  def alive?({:ok, %{a: [_ | _]}}), do: true
  def alive?(_), do: false

  @doc """
  The default resolver: one A query at #{@first_try_ms} ms, a second at
  #{@second_try_ms} ms only when the first one errored. NXDOMAIN and NODATA
  are answers; a second error is `{:unknown, reason}`.
  """
  @spec resolve(String.t()) :: {:ok, %{a: [String.t()]}} | {:unknown, term()}
  def resolve(domain) do
    case LS.DNS.Resolver.a_status(domain, @first_try_ms) do
      {:error, _} ->
        case LS.DNS.Resolver.a_status(domain, @second_try_ms) do
          {:error, reason} -> {:unknown, reason}
          answer -> as_dns(answer)
        end

      answer ->
        as_dns(answer)
    end
  end

  defp as_dns({:ok, ips}), do: {:ok, %{a: ips}}
  defp as_dns(:nxdomain), do: {:ok, %{a: []}}

  @doc """
  Record a check for each dead domain. Returns the number recorded, or the
  ClickHouse error. Nothing is written for an empty list.
  """
  @spec record_dead([due()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def record_dead([]), do: {:ok, 0}

  def record_dead(dead) do
    with {:ok, cols} <- columns() do
      dead
      |> Enum.map(&elem(&1, 0))
      |> Enum.chunk_every(@chunk)
      |> Enum.reduce_while({:ok, 0}, fn chunk, {:ok, n} ->
        case LS.Clickhouse.query_raw(record_dead_sql(cols), 60_000, params: %{doms: LS.Clickhouse.array_param(chunk)}) do
          {:ok, _} -> {:cont, {:ok, n + length(chunk)}}
          {:error, reason} -> {:halt, {:error, {reason, recorded: n}}}
        end
      end)
    end
  end

  @doc false
  def chunk_size, do: @chunk

  @doc """
  Pure: the INSERT ... SELECT that copies each domain's newest `domains` row
  into `enrich_log` with the check's overrides. `cols` is the insertable
  column list of `domains` (no MATERIALIZED columns), in table order.
  """
  @spec record_dead_sql([String.t()]) :: String.t()
  def record_dead_sql(cols) do
    select =
      Enum.map_join(cols, ", ", fn
        "enriched_at" -> "now() AS enriched_at"
        "http_error" -> "'#{@error}' AS http_error"
        "http_status" -> "CAST(NULL AS Nullable(Int32)) AS http_status"
        "worker" -> "'master' AS worker"
        c -> c
      end)

    """
    INSERT INTO #{LS.Schema.Tables.enrich_log()} (#{Enum.join(cols, ", ")})
    SELECT #{select}
    FROM (SELECT * FROM #{LS.Schema.Tables.domains()} WHERE domain IN {doms:Array(String)}
          ORDER BY enriched_at DESC LIMIT 1 BY domain)
    """
  end

  # The insertable columns of `domains`, read once from the server: the
  # list is the table's, not a copy in code that drifts from it.
  defp columns do
    case :persistent_term.get({__MODULE__, :columns}, nil) do
      nil ->
        sql =
          "SELECT name FROM system.columns WHERE database = currentDatabase() " <>
            "AND table = '#{LS.Schema.Tables.domains()}' AND default_kind != 'MATERIALIZED' ORDER BY position"

        case LS.Clickhouse.query_raw(sql, 10_000) do
          {:ok, rows} when rows != [] ->
            cols = Enum.map(rows, fn [n] -> n end)
            :persistent_term.put({__MODULE__, :columns}, cols)
            {:ok, cols}

          {:ok, []} -> {:error, :no_columns}
          err -> err
        end

      cols ->
        {:ok, cols}
    end
  end
end
