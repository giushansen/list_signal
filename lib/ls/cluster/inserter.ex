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
    :ctl_web_scoring, :ctl_budget_scoring, :ctl_security_scoring,
    :dns_a, :dns_aaaa, :dns_mx, :dns_txt, :dns_cname,
    :dns_web_scoring, :dns_email_scoring, :dns_budget_scoring, :dns_security_scoring,
    :http_status, :http_response_time, :http_server, :http_cdn, :http_blocked,
    :http_content_type, :http_tech, :http_tools, :http_is_js_site,
    :http_title, :http_meta_description, :http_pages, :http_emails, :http_error,
    :bgp_ip, :bgp_asn_number, :bgp_asn_org, :bgp_asn_country, :bgp_asn_prefix,
    :bgp_web_scoring, :bgp_budget_scoring,
    # RDAP
    :rdap_domain_created_at, :rdap_domain_expires_at, :rdap_domain_updated_at,
    :rdap_registrar, :rdap_registrar_iana_id, :rdap_nameservers,
    :rdap_status, :rdap_dnssec, :rdap_age_scoring, :rdap_registrar_scoring, :rdap_error,
    # Reputation
    :tranco_rank, :majestic_rank, :majestic_ref_subnets,
    :is_malware, :is_phishing, :is_disposable_email
  ]

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def insert(rows) when is_list(rows), do: GenServer.cast(__MODULE__, {:insert, rows})
  def flush, do: GenServer.call(__MODULE__, :flush, 30_000)
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def init(_opts) do
    schedule_flush()
    Logger.info("💾 Inserter started (#{length(@columns)} columns, flush: #{@flush_size}/#{div(@flush_interval_ms, 1000)}s)")
    {:ok, %{buffer: [], buffer_size: 0, total_inserted: 0, total_batches: 0,
            total_errors: 0, last_insert_at: nil, start_time: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_cast({:insert, rows}, state) do
    state = %{state | buffer: rows ++ state.buffer, buffer_size: state.buffer_size + length(rows)}
    if state.buffer_size >= @flush_size, do: {:noreply, do_flush(state)}, else: {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

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
