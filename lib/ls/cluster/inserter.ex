defmodule LS.Cluster.Inserter do
  @moduledoc """
  Buffers enriched domain rows and batch-inserts into ClickHouse.

  Runs on master node only. Receives results from WorkQueue.complete/2.

  ## Insert strategy

  - Buffers rows in memory (list)
  - Flushes every 5 seconds OR when buffer hits 5000 rows
  - Uses ClickHouse HTTP interface (port 8123) with TSV format
  - Zero external dependencies (just Req.post)

  ## Stats

      LS.Cluster.Inserter.stats()
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
    :bgp_web_scoring, :bgp_budget_scoring
  ]

  # ==========================================================================
  # CLIENT API
  # ==========================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Insert a list of enriched rows. Called by WorkQueue on batch completion."
  def insert(rows) when is_list(rows) do
    GenServer.cast(__MODULE__, {:insert, rows})
  end

  @doc "Force flush buffer to ClickHouse."
  def flush do
    GenServer.call(__MODULE__, :flush, 30_000)
  end

  @doc "Get inserter statistics."
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # ==========================================================================
  # GENSERVER
  # ==========================================================================

  @impl true
  def init(_opts) do
    schedule_flush()

    Logger.info("💾 Inserter started (flush: #{@flush_size} rows or #{div(@flush_interval_ms, 1000)}s)")

    {:ok, %{
      buffer: [],
      buffer_size: 0,
      total_inserted: 0,
      total_batches: 0,
      total_errors: 0,
      last_insert_at: nil,
      start_time: System.monotonic_time(:second)
    }}
  end

  @impl true
  def handle_cast({:insert, rows}, state) do
    new_buffer = rows ++ state.buffer
    new_size = state.buffer_size + length(rows)

    state = %{state | buffer: new_buffer, buffer_size: new_size}

    if new_size >= @flush_size do
      {:noreply, do_flush(state)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    uptime = System.monotonic_time(:second) - state.start_time

    stats = %{
      buffer_size: state.buffer_size,
      total_inserted: state.total_inserted,
      total_batches: state.total_batches,
      total_errors: state.total_errors,
      insert_rate_per_min: if(uptime > 0, do: Float.round(state.total_inserted / uptime * 60, 1), else: 0.0),
      last_insert_at: state.last_insert_at,
      uptime_seconds: uptime
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    state = if state.buffer_size > 0, do: do_flush(state), else: state
    schedule_flush()
    {:noreply, state}
  end

  # ==========================================================================
  # PRIVATE
  # ==========================================================================

  defp do_flush(%{buffer: []} = state), do: state

  defp do_flush(state) do
    rows = Enum.reverse(state.buffer)
    count = state.buffer_size

    case insert_to_clickhouse(rows) do
      :ok ->
        %{state |
          buffer: [],
          buffer_size: 0,
          total_inserted: state.total_inserted + count,
          total_batches: state.total_batches + 1,
          last_insert_at: DateTime.utc_now()
        }

      {:error, reason} ->
        Logger.error("❌ ClickHouse insert failed (#{count} rows): #{inspect(reason)}")
        # Keep buffer — will retry on next flush
        %{state | total_errors: state.total_errors + 1}
    end
  end

  defp insert_to_clickhouse(rows) do
    tsv_body = rows
    |> Enum.map(&row_to_tsv/1)
    |> Enum.join("\n")

    column_names = @columns
    |> Enum.map(&Atom.to_string/1)
    |> Enum.join(", ")

    query = "INSERT INTO #{@ch_db}.#{@ch_table} (#{column_names}) FORMAT TabSeparated"
    url = "#{@ch_url}?query=#{URI.encode(query)}"

    case Req.post(url, body: tsv_body <> "\n", receive_timeout: 30_000) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{String.slice(to_string(body), 0, 200)}"}

      {:error, error} ->
        {:error, inspect(error)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp row_to_tsv(row) do
    @columns
    |> Enum.map(fn col -> escape_tsv(Map.get(row, col, "")) end)
    |> Enum.join("\t")
  end

  defp escape_tsv(nil), do: ""
  defp escape_tsv(value) when is_integer(value), do: Integer.to_string(value)
  defp escape_tsv(value) when is_float(value), do: Float.to_string(value)
  defp escape_tsv(value) when is_atom(value), do: Atom.to_string(value)
  defp escape_tsv(value) when is_list(value), do: Enum.join(value, "|") |> escape_tsv()
  defp escape_tsv(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      :unicode.characters_to_binary(value, :utf8, :utf8)
      |> case do
        {:error, good, _} -> good
        {:incomplete, good, _} -> good
        clean when is_binary(clean) -> clean
      end
    end
    |> String.replace("\\", "")
    |> String.replace("\t", " ")
    |> String.replace("\n", " ")
    |> String.replace("\r", "")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
    |> String.slice(0, 2000)
  end

  defp schedule_flush do
    Process.send_after(self(), :flush_timer, @flush_interval_ms)
  end
end
