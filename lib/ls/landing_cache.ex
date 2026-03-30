defmodule LS.LandingCache do
  @moduledoc """
  ETS-backed cache for landing page data.
  Refreshes from ClickHouse every 60 seconds for real-time numbers.
  All landing page views read from ETS in microseconds.
  """
  use GenServer
  require Logger

  @table :landing_cache
  @refresh_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get cached landing page data. Returns map with all landing metrics."
  def get do
    case :ets.lookup(@table, :landing) do
      [{:landing, data}] -> data
      _ -> defaults()
    end
  rescue
    _ -> defaults()
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.insert(@table, {:landing, defaults()})
    send(self(), :refresh)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    data = fetch_all()
    :ets.insert(@table, {:landing, data})
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  defp fetch_all do
    insert_last_min = fetch_count("SELECT count() FROM enrichments WHERE enriched_at >= now() - INTERVAL 1 MINUTE")
    %{
      store_count: fetch_count("SELECT count() FROM domains_current WHERE http_tech LIKE '%Shopify%'"),
      total_domains: fetch_count("SELECT count() FROM domains_current"),
      tech_count: fetch_count("SELECT uniq(arrayJoin(splitByString('|', http_tech))) FROM domains_current WHERE http_tech != ''"),
      app_count: fetch_count("SELECT uniq(arrayJoin(splitByString('|', http_apps))) FROM domains_current WHERE http_apps != ''"),
      scan_rate: insert_last_min,
      ch_insert_rate: insert_last_min,
      ctl_rate_per_sec: fetch_ctl_rate(),
      stores_last_hour: fetch_count("SELECT count() FROM enrichments WHERE enriched_at >= now() - INTERVAL 1 HOUR"),
      recent_stores: fetch_recent_stores(),
      top_stores: fetch_top_stores(),
      refreshed_at: DateTime.utc_now()
    }
  end

  defp fetch_ctl_rate do
    # Try to get real CTL scanning rate from the Poller process
    if Process.whereis(LS.CTL.Poller) do
      try do
        stats = LS.CTL.Poller.stats()
        rate = stats[:domains_per_sec] || 0.0
        if rate > 0, do: rate, else: 0.0
      catch
        _, _ -> 0.0
      end
    else
      0.0
    end
  end

  defp fetch_count(sql) do
    case LS.Clickhouse.query_raw(sql) do
      {:ok, [[n]]} when is_integer(n) -> n
      {:ok, [[n]]} when is_float(n) -> round(n)
      {:ok, [[n]]} when is_binary(n) -> String.to_integer(n)
      other ->
        Logger.warning("LandingCache fetch_count failed: #{inspect(other)} for: #{sql}")
        0
    end
  end

  defp fetch_recent_stores do
    case LS.Clickhouse.recent_stores(20) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{domain: Enum.at(row, 0) || "", country: Enum.at(row, 1) || "",
            title: Enum.at(row, 2) || "", tech: Enum.at(row, 3) || "",
            enriched_at: Enum.at(row, 4)}
        end)
      _ -> []
    end
  end

  defp fetch_top_stores do
    case LS.Clickhouse.sample_shopify_stores(10) do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{domain: Enum.at(row, 0) || "", title: Enum.at(row, 1) || "",
            tech: Enum.at(row, 2) || "", country: Enum.at(row, 3) || "",
            rank: Enum.at(row, 4)}
        end)
      _ -> []
    end
  end

  defp defaults do
    %{store_count: 0, total_domains: 0, tech_count: 0, app_count: 0,
      scan_rate: 0, ch_insert_rate: 0, ctl_rate_per_sec: 0.0,
      stores_last_hour: 0,
      recent_stores: [], top_stores: [], refreshed_at: nil}
  end
end
