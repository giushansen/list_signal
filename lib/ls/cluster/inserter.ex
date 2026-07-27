defmodule LS.Cluster.Inserter do
  @moduledoc """
  Buffers enriched domain rows and batch-inserts into ClickHouse.
  Runs on master node only. Flushes every 5s or at 5000 rows.
  """

  use GenServer
  require Logger

  @flush_interval_ms 5_000
  @flush_size 5_000
  @ch_url "http://127.0.0.1:8123/"
  @ch_db "ls"
  @ch_table "enrichments"

  @columns [
    :enriched_at, :worker, :domain,
    :ctl_tld, :ctl_issuer, :ctl_subdomain_count, :ctl_subdomains,
    :dns_a, :dns_aaaa, :dns_mx, :dns_txt, :dns_cname,
    :http_status, :http_response_time, :http_blocked,
    :http_content_type, :http_tech, :http_apps, :http_language,
    :http_title, :http_meta_description, :http_pages, :http_emails, :http_error,
    :http_h1, :http_body_snippet,
    # Classification
    :business_model, :industry, :classification_confidence,
    :http_schema_type, :http_og_type,
    :bgp_ip, :bgp_asn_number, :bgp_asn_org, :bgp_asn_country, :bgp_asn_prefix,
    :inferred_country,
    # RDAP
    :rdap_domain_created_at, :rdap_domain_expires_at, :rdap_domain_updated_at,
    :rdap_registrar, :rdap_registrar_iana_id, :rdap_nameservers,
    :rdap_status, :rdap_error,
    # Reputation
    :tranco_rank, :majestic_rank, :majestic_ref_subnets,
    :is_malware, :is_phishing, :is_disposable_email,
    # Revenue estimation
    :estimated_revenue, :estimated_employees, :revenue_confidence, :revenue_evidence
  ]

  def columns, do: @columns

  # `:name` is overridable so tests can run an isolated instance instead of
  # sharing the supervised singleton's buffer and guard state.
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def insert(server \\ __MODULE__, rows) when is_list(rows),
    do: GenServer.cast(server, {:insert, rows})

  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    schedule_flush()
    Logger.info("💾 Inserter started (#{length(@columns)} columns, flush: #{@flush_size}/#{div(@flush_interval_ms, 1000)}s)")
    {:ok, %{buffer: [], buffer_size: 0, total_inserted: 0, total_batches: 0,
            total_errors: 0, last_insert_at: nil, start_time: System.monotonic_time(:second),
            worker_health: %{}}}
  end

  @doc """
  Per-worker health as tracked by the quality guard.

  `%{"worker_lsny1@10.0.0.2" => %{ratio: 0.99, quarantined: false, dropped: 0}, ...}`
  Clear a quarantine with `release_worker/1` once the node is fixed.
  """
  def worker_health(server \\ __MODULE__), do: GenServer.call(server, :worker_health)

  def release_worker(server \\ __MODULE__, worker),
    do: GenServer.call(server, {:release_worker, worker})

  @impl true
  def handle_cast({:insert, rows}, state) do
    {rows, state} = guard_batch(rows, state)
    state = %{state | buffer: rows ++ state.buffer, buffer_size: state.buffer_size + length(rows)}
    if state.buffer_size >= @flush_size, do: {:noreply, do_flush(state)}, else: {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  @impl true
  def handle_call(:worker_health, _from, state) do
    report =
      Map.new(state.worker_health, fn {w, h} ->
        {w, %{ratio: h.ratio, quarantined: h.quarantined, dropped: h.dropped}}
      end)

    {:reply, report, state}
  end

  @impl true
  def handle_call({:release_worker, worker}, _from, state) do
    case Map.fetch(state.worker_health, worker) do
      {:ok, h} ->
        Logger.warning("[GUARD] Releasing #{worker} from quarantine (#{h.dropped} rows were dropped)")
        health = %{h | quarantined: false, seen: 0, good: 0, dropped: 0}
        {:reply, :ok, put_health(state, worker, health)}

      :error ->
        {:reply, {:error, :unknown_worker}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time
    {:reply, %{
      buffer_size: state.buffer_size, total_inserted: state.total_inserted,
      total_batches: state.total_batches, total_errors: state.total_errors,
      insert_rate_per_min: if(uptime > 0, do: Float.round(state.total_inserted / uptime * 60, 1), else: 0.0),
      last_insert_at: state.last_insert_at, uptime_seconds: uptime
    }, state}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    state = if state.buffer_size > 0, do: do_flush(state), else: state
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.buffer_size > 0 do
      Logger.info("Inserter terminating — flushing #{state.buffer_size} rows")
      do_flush(state)
    end
    :ok
  end

  defp do_flush(%{buffer: []} = state), do: state
  defp do_flush(state) do
    rows = Enum.reverse(state.buffer)
    count = state.buffer_size
    case insert_to_clickhouse(rows) do
      :ok ->
        %{state | buffer: [], buffer_size: 0, total_inserted: state.total_inserted + count,
          total_batches: state.total_batches + 1, last_insert_at: DateTime.utc_now()}
      {:error, reason} ->
        Logger.error("❌ ClickHouse insert failed (#{count} rows): #{inspect(reason)}")
        %{state | total_errors: state.total_errors + 1}
    end
  end

  defp insert_to_clickhouse(rows) do
    tsv = rows |> Enum.map(&row_to_tsv/1) |> Enum.join("\n")
    cols = @columns |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")
    query = "INSERT INTO #{@ch_db}.#{@ch_table} (#{cols}) FORMAT TabSeparated"
    url = "#{@ch_url}?query=#{URI.encode(query)}"
    case Req.post(url, body: tsv <> "\n", receive_timeout: 30_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s, body: b}} -> {:error, "HTTP #{s}: #{String.slice(to_string(b), 0, 200)}"}
      {:error, e} -> {:error, inspect(e)}
    end
  rescue e -> {:error, Exception.message(e)}
  end

  # ── Data-quality guard ──────────────────────────────────────────────────────
  #
  # Catches a worker whose enrichment stages have silently died while DNS still
  # works, so it keeps claiming batches and writing hollow rows. Because
  # `domains_current` is a ReplacingMergeTree(enriched_at) keyed on domain, a
  # hollow row REPLACES good data — a sick worker actively destroys the dataset.
  # h1 did exactly this from 2026-07-04 for 21 days: ~56M empty rows, ~933K
  # domains degraded from good to blank, nothing alerted.
  #
  # Metric: of rows where DNS resolved, the fraction that got ANY enrichment
  # beyond DNS (HTTP status, BGP or RDAP). Over 30 days of history the five
  # healthy workers never dropped below 0.984 in any hour (median 1.000) while
  # h1 sat at exactly 0.000 for all 686 of its hours — so 0.5 is far from both.
  #
  # Dropping a sick worker's rows is strictly safer than writing them: the
  # domain keeps its previous good data and stays eligible for recrawl.
  @guard_min_sample 2_000
  @guard_min_ratio 0.5

  defp guard_batch(rows, state) do
    rows
    |> Enum.group_by(&Map.get(&1, :worker, "unknown"))
    |> Enum.reduce({[], state}, fn {worker, wrows}, {kept, st} ->
      health = Map.get(st.worker_health, worker, %{seen: 0, good: 0, ratio: nil,
                                                   quarantined: false, dropped: 0})

      if health.quarantined do
        health = %{health | dropped: health.dropped + length(wrows)}
        if rem(health.dropped, 50_000) < length(wrows) do
          Logger.error("[GUARD] #{worker} still QUARANTINED — #{health.dropped} rows dropped. " <>
                       "Fix the node, then LS.Cluster.Inserter.release_worker(#{inspect(worker)})")
        end
        {kept, put_health(st, worker, health)}
      else
        eligible = Enum.count(wrows, &(Map.get(&1, :dns_a, "") != ""))
        good = Enum.count(wrows, &enriched_beyond_dns?/1)
        health = %{health | seen: health.seen + eligible, good: health.good + good}

        {health, st} = evaluate(worker, health, st)
        {wrows ++ kept, put_health(st, worker, health)}
      end
    end)
  end

  defp evaluate(worker, %{seen: seen} = health, st) when seen >= @guard_min_sample do
    ratio = health.good / seen

    health =
      if ratio < @guard_min_ratio do
        Logger.error("[GUARD] QUARANTINING #{worker} — only #{Float.round(ratio * 100, 1)}% of " <>
                     "DNS-resolved rows got any enrichment beyond DNS (min #{@guard_min_ratio * 100}%, " <>
                     "sample #{seen}). Its rows are now DROPPED so they can't overwrite good data. " <>
                     "Likely a broken OS resolver or blocked egress on that node.")
        %{health | quarantined: true, ratio: ratio}
      else
        %{health | ratio: ratio}
      end

    # reset the rolling window either way
    {%{health | seen: 0, good: 0}, st}
  end

  defp evaluate(_worker, health, st), do: {health, st}

  defp put_health(st, worker, health),
    do: %{st | worker_health: Map.put(st.worker_health, worker, health)}

  defp enriched_beyond_dns?(row) do
    Map.get(row, :dns_a, "") != "" and
      (Map.get(row, :http_status) != nil or
         Map.get(row, :bgp_asn_number, "") != "" or
         Map.get(row, :rdap_registrar, "") != "")
  end

  defp row_to_tsv(row), do: @columns |> Enum.map(fn c -> escape_tsv(Map.get(row, c, "")) end) |> Enum.join("\t")

  defp escape_tsv(nil), do: "\\N"
  defp escape_tsv(v) when is_integer(v), do: Integer.to_string(v)
  defp escape_tsv(v) when is_float(v), do: Float.to_string(v)
  defp escape_tsv(v) when is_atom(v), do: Atom.to_string(v)
  defp escape_tsv(v) when is_list(v), do: Enum.join(v, "|") |> escape_tsv()
  defp escape_tsv(v) when is_binary(v) do
    v = if String.valid?(v), do: v,
    else: (case :unicode.characters_to_binary(v, :utf8, :utf8) do
      {:error, g, _} -> g; {:incomplete, g, _} -> g; c when is_binary(c) -> c end)
    v |> String.replace("\\", "") |> String.replace("\t", " ") |> String.replace("\n", " ")
    |> String.replace("\r", "") |> String.replace(~r/[\x00-\x1F\x7F]/, "") |> String.slice(0, 2000)
  end

  defp schedule_flush, do: Process.send_after(self(), :flush_timer, @flush_interval_ms)
end
